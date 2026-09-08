// dist/intermediate/bridge/SharedBufferLayout.js
var IMU_HEAD_OFFSET = 0;
var IMU_TAIL_OFFSET = 4;
var IMU_DATA_OFFSET = 8;
var IMU_PACKET_SIZE = 64;
var IMU_RING_CAPACITY = 64;
var IMU_BUF_SIZE = IMU_DATA_OFFSET + IMU_RING_CAPACITY * IMU_PACKET_SIZE;
var MCU_CMD_READY_OFFSET = 0;
var MCU_CMD_DATA_OFFSET = 4;
var MCU_RSP_READY_OFFSET = 4 + 512;
var MCU_RSP_DATA_OFFSET = 4 + 512 + 4;
var MCU_RSP_DATA_SIZE = 512;
var MCU_BUF_SIZE = MCU_RSP_DATA_OFFSET + MCU_RSP_DATA_SIZE;

// dist/intermediate/bridge/WebHidBridge.js
var VITURE_VID = 13770;
var VITURE_PIDS = [
  4113,
  4115,
  4117,
  4119,
  4123,
  // Viture One / Viture Lite variants
  4121,
  4125,
  // Viture Pro variants
  4385,
  4401,
  4417,
  4433,
  // Luma / Luma Pro variants
  4609,
  4625,
  // Beast variants
  4865
  // Pro 2
];
var REPORT_ID_MCU = 0;
var CMD_POLL_INTERVAL_MS = 1;
var WebHidBridge = class {
  mod;
  // HID devices (may be 1 or 2 depending on OS enumeration mode).
  devices = [];
  // Identifies which device carries the IMU interface (Gen1 devices).
  // null for Gen2 (no dedicated IMU interface).
  imuDevice = null;
  // Identifies which device carries the MCU interface (all devices).
  mcuDevice = null;
  // WASM heap pointers (allocated in connect(), freed in disconnect()).
  imuPtr = 0;
  mcuPtr = 0;
  // SDK handle returned by xr_device_provider_create().
  handle = 0;
  // Polling timer for cmd_ready.
  pollTimer = null;
  // Int32Array view over the MCU channel for Atomics operations.
  // Lazily constructed in connect() once mcuPtr is known.
  mcuView = null;
  // Bytes to send per MCU command; set in connect() (64 for all devices).
  mcuCmdSize = IMU_PACKET_SIZE;
  // Product ID detected during connect().
  productId = 0;
  stateCallback = null;
  _cmdSeq = 0;
  // monotonic counter; used for first-command auto-swap guard
  _cmdPending = false;
  // true between pollCmd seeing cmd_ready and writeMcuResponse
  constructor(mod) {
    this.mod = mod;
  }
  // -----------------------------------------------------------------------
  // Public API
  // -----------------------------------------------------------------------
  onState(cb) {
    this.stateCallback = cb;
  }
  // -----------------------------------------------------------------------
  // Logging
  // -----------------------------------------------------------------------
  log(msg) {
    console.log(`[WHB] ${msg}`);
  }
  logWarn(msg) {
    console.warn(`[WHB] ${msg}`);
  }
  static hexBytes(data, maxBytes = 8) {
    return Array.from(data.slice(0, maxBytes)).map((b) => b.toString(16).padStart(2, "0")).join(" ");
  }
  getHandle() {
    return this.handle;
  }
  getProductId() {
    return this.productId;
  }
  /**
   * Open a Viture device.  MUST be called from inside a user-gesture handler
   * (click, keydown, etc.) because navigator.hid.requestDevice() requires it.
   * Product ID is auto-detected from the device granted by the user.
   */
  async connect() {
    this._cmdSeq = 0;
    this._cmdPending = false;
    const filters = VITURE_PIDS.map((pid) => ({ vendorId: VITURE_VID, productId: pid }));
    const granted = await navigator.hid.requestDevice({ filters });
    if (granted.length === 0) {
      throw new Error("WebHID: no device selected");
    }
    this.devices = [...granted];
    for (const dev of this.devices) {
      if (!dev.opened)
        await dev.open();
    }
    const productId = granted[0].productId;
    const allGranted = await navigator.hid.getDevices();
    for (const dev of allGranted) {
      if (dev.vendorId === VITURE_VID && dev.productId === productId && !this.devices.includes(dev)) {
        if (!dev.opened)
          await dev.open();
        this.devices.push(dev);
      }
    }
    this.productId = productId;
    this.mcuCmdSize = IMU_PACKET_SIZE;
    this.identifyInterfaces(productId);
    if (!this.mcuDevice) {
      throw new Error("WebHID: could not identify MCU interface");
    }
    this.imuPtr = this.mod._malloc(IMU_BUF_SIZE);
    this.mcuPtr = this.mod._malloc(MCU_BUF_SIZE);
    this.zeroControlFields();
    this.mod.ccall("xr_webhid_set_imu_buffer", null, ["number", "number"], [this.imuPtr, this.isV2(productId) ? 0 : IMU_RING_CAPACITY]);
    this.mod.ccall("xr_webhid_set_mcu_buffer", null, ["number"], [this.mcuPtr]);
    this.handle = this.mod.ccall("xr_device_provider_create", "number", ["number"], [productId]);
    if (!this.handle) {
      throw new Error(`xr_device_provider_create failed for pid=0x${productId.toString(16)}`);
    }
    const initRet = this.mod.ccall("xr_device_provider_initialize", "number", ["number", "number", "number"], [this.handle, 0, 0]);
    if (initRet !== 0) {
      throw new Error(`xr_device_provider_initialize failed: ${initRet}`);
    }
    if (!this.isV2(productId) && this.devices.length === 2 && this.imuDevice !== this.mcuDevice) {
      await this.probeAndCorrectInterfaces();
    }
    const startRet = this.mod.ccall("xr_device_provider_start", "number", ["number"], [this.handle]);
    if (startRet !== 0) {
      throw new Error(`xr_device_provider_start failed: ${startRet}`);
    }
    this.mcuView = new Int32Array(this.mod.HEAPU8.buffer, this.mcuPtr, MCU_BUF_SIZE / 4);
    for (const dev of this.devices) {
      dev.oninputreport = (ev) => this.onInputReport(dev, ev);
    }
    this.startCmdPoll();
    window.vhbSwapInterfaces = () => {
      if (this.devices.length < 2) {
        console.warn("[WHB] vhbSwapInterfaces: only 1 device, nothing to swap");
        return;
      }
      const tmp = this.imuDevice;
      this.imuDevice = this.mcuDevice;
      this.mcuDevice = tmp;
      console.log(`[WHB] vhbSwapInterfaces: swapped -- imuDevice="${this.imuDevice?.productName ?? "null"}" mcuDevice="${this.mcuDevice?.productName ?? "null"}"`);
    };
    this.stateCallback?.(true);
  }
  async disconnect() {
    this.stateCallback?.(false);
    this.stopCmdPoll();
    for (const dev of this.devices) {
      dev.oninputreport = null;
    }
    if (this.handle) {
      this.mod.ccall("xr_device_provider_stop", "number", ["number"], [this.handle]);
      this.mod.ccall("xr_device_provider_shutdown", "number", ["number"], [this.handle]);
      this.mod.ccall("xr_device_provider_destroy", null, ["number"], [this.handle]);
      this.handle = 0;
    }
    if (this.imuPtr) {
      this.mod._free(this.imuPtr);
      this.imuPtr = 0;
    }
    if (this.mcuPtr) {
      this.mod._free(this.mcuPtr);
      this.mcuPtr = 0;
    }
    this.mcuView = null;
    for (const dev of this.devices) {
      try {
        await dev.close();
      } catch {
      }
    }
    this.devices = [];
    this.imuDevice = null;
    this.mcuDevice = null;
  }
  // -----------------------------------------------------------------------
  // Private: interface identification
  // -----------------------------------------------------------------------
  /**
   * Active probing: call a C++ query function to verify which device responds.
   * This is called after initialize() but before start(), when the command queue
   * is active but IMU streaming hasn't started yet.
   *
   * Strategy:
   *   1. Wire up oninputreport handlers temporarily
   *   2. Start command polling manually
   *   3. Call xr_device_provider_get_display_mode() (sends command to mcuDevice)
   *   4. Wait for a response (C++ SendQueue ACK timeout bounds the wait)
   *   5. If no response, swap mcuDevice/imuDevice and try again
   *   6. Once we get a response, the assignment is correct
   */
  async probeAndCorrectInterfaces() {
    this.mcuView = new Int32Array(this.mod.HEAPU8.buffer, this.mcuPtr, MCU_BUF_SIZE / 4);
    const tempHandler = (_dev, ev) => {
      const data = new Uint8Array(ev.data.buffer, ev.data.byteOffset, ev.data.byteLength);
      if (data.byteLength === IMU_PACKET_SIZE || data.byteLength === this.mcuCmdSize) {
        this.writeMcuResponse(data);
      }
    };
    for (const dev of this.devices) {
      dev.oninputreport = (ev) => tempHandler(dev, ev);
    }
    let probePollInterval = null;
    const startProbePolling = () => {
      probePollInterval = window.setInterval(() => {
        const cmdReady = Atomics.load(this.mcuView, MCU_CMD_READY_OFFSET / 4);
        if (cmdReady !== 0) {
          const cmdLen = this.mcuCmdSize;
          const sharedView = new Uint8Array(this.mod.HEAPU8.buffer, this.mcuPtr + MCU_CMD_DATA_OFFSET, cmdLen);
          const cmdData = new Uint8Array(cmdLen);
          cmdData.set(sharedView);
          this.mcuDevice.sendReport(0, cmdData).then(() => {
            Atomics.store(this.mcuView, MCU_CMD_READY_OFFSET / 4, 0);
            Atomics.notify(this.mcuView, MCU_CMD_READY_OFFSET / 4);
          }).catch((err) => {
            this.logWarn(`probeAndCorrectInterfaces: sendReport failed: ${err}`);
            Atomics.store(this.mcuView, MCU_CMD_READY_OFFSET / 4, 0);
            Atomics.notify(this.mcuView, MCU_CMD_READY_OFFSET / 4);
          });
        }
      }, CMD_POLL_INTERVAL_MS);
    };
    const stopProbePolling = () => {
      if (probePollInterval !== null) {
        clearInterval(probePollInterval);
        probePollInterval = null;
      }
    };
    startProbePolling();
    const ret1 = await this.probeWithTimeout(500);
    if (ret1 >= 0) {
      this.log(`probeAndCorrectInterfaces: probe #1 succeeded, display_mode=${ret1} -- interface assignment correct`);
      stopProbePolling();
      for (const dev of this.devices) {
        dev.oninputreport = null;
      }
      return;
    }
    this.logWarn(`probeAndCorrectInterfaces: probe #1 timeout -- swapping interfaces`);
    const tmp = this.imuDevice;
    this.imuDevice = this.mcuDevice;
    this.mcuDevice = tmp;
    this.log(`probeAndCorrectInterfaces: swapped to mcuDevice="${this.mcuDevice?.productName}"`);
    const ret2 = await this.probeWithTimeout(500);
    if (ret2 >= 0) {
      this.log(`probeAndCorrectInterfaces: probe #2 succeeded, display_mode=${ret2} -- corrected interface assignment`);
    } else {
      this.logWarn(`probeAndCorrectInterfaces: both probe attempts failed -- keeping swapped assignment`);
    }
    stopProbePolling();
    for (const dev of this.devices) {
      dev.oninputreport = null;
    }
  }
  /**
   * Call xr_device_provider_get_display_mode() and wait for response.
   * Returns display mode (>=0) on success, -1 on timeout or error.
   *
   * The C++ call uses emscripten_sleep internally (ASYNCIFY).  Only one
   * asyncified ccall may be pending on the main thread at a time.  The
   * outer promise MUST therefore wait for the ccall to complete fully
   * before returning -- starting the next probe while a ccall is still
   * suspended would corrupt Asyncify.currData and crash the WASM module.
   *
   * The timeoutMs window is used solely to decide the return value: if the
   * C++ ACK arrives after the window we still report -1 (timeout), but we
   * always drain the ccall first.  The actual upper bound on wait time is
   * the C++ SendQueue ACK timeout (~1 s).
   */
  async probeWithTimeout(timeoutMs) {
    const result = this.mod.ccall("xr_device_provider_get_display_mode", "number", ["number"], [this.handle]);
    const ccallPromise = result instanceof Promise ? result : Promise.resolve(result);
    let timedOut = false;
    const timerId = setTimeout(() => {
      timedOut = true;
    }, timeoutMs);
    try {
      const mode = await ccallPromise;
      clearTimeout(timerId);
      return timedOut ? -1 : mode;
    } catch (err) {
      clearTimeout(timerId);
      this.logWarn(`probeWithTimeout: xr_device_provider_get_display_mode threw: ${err}`);
      return -1;
    }
  }
  /**
   * Given one or two HIDDevice objects returned by requestDevice(), determine
   * which carries the IMU interface and which carries the MCU interface.
   *
   * Two enumeration modes are handled:
   *
   *   Mode A -- two separate HIDDevice objects (one per USB interface):
   *     The device that has a 64-byte usage length is the IMU interface.
   *     The other is the MCU interface.
   *     For Gen2 only one device is expected (single MCU interface, 512-byte).
   *
   *   Mode B -- single HIDDevice with multiple collections:
   *     Both imuDevice and mcuDevice point to the same HIDDevice object.
   *     Report dispatch relies on reportId or packet size at runtime.
   */
  identifyInterfaces(productId) {
    if (this.isV2(productId)) {
      this.imuDevice = null;
      this.mcuDevice = this.devices[0];
      return;
    }
    if (this.devices.length === 1) {
      this.imuDevice = this.devices[0];
      this.mcuDevice = this.devices[0];
      return;
    }
    for (const dev of this.devices) {
      const hasWriteReports = dev.collections.some((c) => (c.outputReports ?? []).length > 0 || (c.featureReports ?? []).length > 0);
      if (hasWriteReports) {
        this.mcuDevice = dev;
      } else {
        this.imuDevice = dev;
      }
    }
    if (!this.imuDevice) {
      this.logWarn(`identifyInterfaces: no IMU device identified by heuristic -- falling back to devices[0]`);
      this.imuDevice = this.devices[0];
    }
    if (!this.mcuDevice) {
      this.logWarn(`identifyInterfaces: no MCU device identified by heuristic -- falling back to devices[1]`);
      this.mcuDevice = this.devices[1] ?? this.devices[0];
    }
  }
  // -----------------------------------------------------------------------
  // Private: oninputreport dispatch
  // -----------------------------------------------------------------------
  onInputReport(dev, ev) {
    const data = new Uint8Array(ev.data.buffer, ev.data.byteOffset, ev.data.byteLength);
    if (dev === this.imuDevice && dev !== this.mcuDevice) {
      this.writeImuPacket(data);
    } else if (dev === this.mcuDevice && dev !== this.imuDevice) {
      this.writeMcuResponse(data);
    } else {
      if (data.byteLength <= IMU_PACKET_SIZE && this.imuPtr) {
        this.writeImuPacket(data);
      } else {
        this.writeMcuResponse(data);
      }
    }
  }
  // -----------------------------------------------------------------------
  // Private: IMU ring buffer write
  // -----------------------------------------------------------------------
  writeImuPacket(data) {
    if (!this.imuPtr)
      return;
    const heap = this.mod.HEAPU8;
    const imuI32 = new Int32Array(heap.buffer, this.imuPtr, 2);
    const head = Atomics.load(imuI32, 0);
    const tail = Atomics.load(imuI32, 1);
    const nextHead = (head + 1) % IMU_RING_CAPACITY;
    if (nextHead === tail) {
      return;
    }
    const slotOffset = this.imuPtr + IMU_DATA_OFFSET + head * IMU_PACKET_SIZE;
    const copyLen = Math.min(data.byteLength, IMU_PACKET_SIZE);
    heap.set(data.subarray(0, copyLen), slotOffset);
    Atomics.store(imuI32, 0, nextHead);
    Atomics.notify(imuI32, 0, 1);
  }
  // -----------------------------------------------------------------------
  // Private: MCU response channel write
  // -----------------------------------------------------------------------
  writeMcuResponse(data) {
    if (!this.mcuPtr)
      return;
    const heap = this.mod.HEAPU8;
    const copyLen = Math.min(data.byteLength, MCU_RSP_DATA_SIZE);
    heap.set(data.subarray(0, copyLen), this.mcuPtr + MCU_RSP_DATA_OFFSET);
    const rspView = new Int32Array(heap.buffer, this.mcuPtr + MCU_RSP_READY_OFFSET, 1);
    const prev = Atomics.exchange(rspView, 0, 1);
    if (prev === 1) {
      this.logWarn(`writeMcuResponse: rsp_ready was already 1 -- previous response not consumed yet (overwritten)`);
    }
    this._cmdPending = false;
    Atomics.notify(rspView, 0, 1);
  }
  // -----------------------------------------------------------------------
  // Private: MCU command poll
  // -----------------------------------------------------------------------
  startCmdPoll() {
    this.pollTimer = setInterval(() => this.pollCmd(), CMD_POLL_INTERVAL_MS);
  }
  stopCmdPoll() {
    if (this.pollTimer !== null) {
      clearInterval(this.pollTimer);
      this.pollTimer = null;
    }
  }
  pollCmd() {
    if (!this.mcuView || !this.mcuDevice)
      return;
    const ready = Atomics.load(this.mcuView, MCU_CMD_READY_OFFSET / 4);
    if (ready !== 1)
      return;
    const heap = this.mod.HEAPU8;
    const cmd = heap.slice(this.mcuPtr + MCU_CMD_DATA_OFFSET, this.mcuPtr + MCU_CMD_DATA_OFFSET + this.mcuCmdSize);
    Atomics.store(this.mcuView, MCU_CMD_READY_OFFSET / 4, 0);
    const seq = this._cmdSeq++;
    this._cmdPending = true;
    if (seq === 0) {
      setTimeout(() => {
        if (this._cmdPending && this.devices.length === 2) {
          this.logWarn(`pollCmd: first command timeout -- interface assignment likely wrong, auto-swapping`);
          const tmp = this.imuDevice;
          this.imuDevice = this.mcuDevice;
          this.mcuDevice = tmp;
          this._cmdPending = false;
          this.log(`auto-swap done: imuDevice="${this.imuDevice?.productName ?? "null"}" mcuDevice="${this.mcuDevice?.productName ?? "null"}"`);
        }
      }, 2e3);
    }
    this.sendCmd(cmd, seq);
  }
  sendCmd(cmd, seq) {
    const hasOutput = this.mcuDevice.collections.some((c) => (c.outputReports ?? []).length > 0);
    if (!hasOutput) {
      this.logWarn(`cmd #${seq}: sending to a device without outputReports`);
    }
    this.mcuDevice.sendReport(REPORT_ID_MCU, cmd).catch((err) => {
      this.logWarn(`cmd #${seq}: sendReport FAILED: ${err}`);
    });
  }
  // -----------------------------------------------------------------------
  // Private: helpers
  // -----------------------------------------------------------------------
  isV2(productId) {
    const prefix = productId & 65280;
    return prefix === 4608 || prefix === 4864;
  }
  zeroControlFields() {
    this.mod.setValue(this.imuPtr + IMU_HEAD_OFFSET, 0, "i32");
    this.mod.setValue(this.imuPtr + IMU_TAIL_OFFSET, 0, "i32");
    this.mod.setValue(this.mcuPtr + MCU_CMD_READY_OFFSET, 0, "i32");
    this.mod.setValue(this.mcuPtr + MCU_RSP_READY_OFFSET, 0, "i32");
  }
};

// dist/intermediate/types.js
var VITURE_DISPLAY_MODE_1920_1080_60HZ = 49;
var VITURE_DISPLAY_MODE_3840_1080_60HZ = 50;
var VITURE_DISPLAY_MODE_1920_1080_90HZ = 51;
var VITURE_DISPLAY_MODE_1920_1080_120HZ = 52;
var VITURE_DISPLAY_MODE_3840_1080_90HZ = 53;
var VITURE_DISPLAY_MODE_1920_1200_60HZ = 65;
var VITURE_DISPLAY_MODE_3840_1200_60HZ = 66;
var VITURE_DISPLAY_MODE_1920_1200_90HZ = 67;
var VITURE_DISPLAY_MODE_1920_1200_120HZ = 68;
var VITURE_DISPLAY_MODE_3840_1200_90HZ = 69;
var DISPLAY_MODES = [
  { label: "1920x1080 @ 60Hz", value: VITURE_DISPLAY_MODE_1920_1080_60HZ },
  { label: "3840x1080 @ 60Hz", value: VITURE_DISPLAY_MODE_3840_1080_60HZ },
  { label: "1920x1080 @ 90Hz", value: VITURE_DISPLAY_MODE_1920_1080_90HZ },
  { label: "1920x1080 @ 120Hz", value: VITURE_DISPLAY_MODE_1920_1080_120HZ },
  { label: "3840x1080 @ 90Hz", value: VITURE_DISPLAY_MODE_3840_1080_90HZ },
  { label: "1920x1200 @ 60Hz", value: VITURE_DISPLAY_MODE_1920_1200_60HZ },
  { label: "3840x1200 @ 60Hz", value: VITURE_DISPLAY_MODE_3840_1200_60HZ },
  { label: "1920x1200 @ 90Hz", value: VITURE_DISPLAY_MODE_1920_1200_90HZ },
  { label: "1920x1200 @ 120Hz", value: VITURE_DISPLAY_MODE_1920_1200_120HZ },
  { label: "3840x1200 @ 90Hz", value: VITURE_DISPLAY_MODE_3840_1200_90HZ }
];
var VITURE_NATIVE_DISPLAY_MODE_1920_1080_60HZ = 49;
var VITURE_NATIVE_DISPLAY_MODE_1920_1080_90HZ = 50;
var VITURE_NATIVE_DISPLAY_MODE_1920_1080_120HZ = 51;
var VITURE_NATIVE_DISPLAY_MODE_1920_1200_60HZ = 52;
var VITURE_NATIVE_DISPLAY_MODE_1920_1200_90HZ = 53;
var VITURE_NATIVE_DISPLAY_MODE_1920_1200_120HZ = 54;
var VITURE_NATIVE_DISPLAY_MODE_3D_SBS_3840_1080_60HZ = 55;
var VITURE_NATIVE_DISPLAY_MODE_3D_SBS_3840_1080_90HZ = 56;
var VITURE_NATIVE_DISPLAY_MODE_3D_SBS_3840_1080_120HZ = 57;
var VITURE_NATIVE_DISPLAY_MODE_3D_SBS_3840_1200_60HZ = 58;
var VITURE_NATIVE_DISPLAY_MODE_3D_SBS_3840_1200_90HZ = 59;
var VITURE_NATIVE_DISPLAY_MODE_3D_SBS_3840_1200_120HZ = 60;
var VITURE_NATIVE_DISPLAY_MODE_ULTRAWIDE_3840_1080_60HZ = 61;
var VITURE_NATIVE_DISPLAY_MODE_ULTRAWIDE_3840_1080_90HZ = 62;
var VITURE_NATIVE_DISPLAY_MODE_ULTRAWIDE_3840_1080_120HZ = 63;
var VITURE_NATIVE_DISPLAY_MODE_ULTRAWIDE_3840_1200_60HZ = 64;
var VITURE_NATIVE_DISPLAY_MODE_ULTRAWIDE_3840_1200_90HZ = 65;
var VITURE_NATIVE_DISPLAY_MODE_ULTRAWIDE_3840_1200_120HZ = 66;
var NATIVE_DISPLAY_MODES = [
  { label: "1920x1080 @ 60Hz", value: VITURE_NATIVE_DISPLAY_MODE_1920_1080_60HZ },
  { label: "1920x1080 @ 90Hz", value: VITURE_NATIVE_DISPLAY_MODE_1920_1080_90HZ },
  { label: "1920x1080 @ 120Hz", value: VITURE_NATIVE_DISPLAY_MODE_1920_1080_120HZ },
  { label: "1920x1200 @ 60Hz", value: VITURE_NATIVE_DISPLAY_MODE_1920_1200_60HZ },
  { label: "1920x1200 @ 90Hz", value: VITURE_NATIVE_DISPLAY_MODE_1920_1200_90HZ },
  { label: "1920x1200 @ 120Hz", value: VITURE_NATIVE_DISPLAY_MODE_1920_1200_120HZ },
  { label: "3D SBS 3840x1080 @ 60Hz", value: VITURE_NATIVE_DISPLAY_MODE_3D_SBS_3840_1080_60HZ },
  { label: "3D SBS 3840x1080 @ 90Hz", value: VITURE_NATIVE_DISPLAY_MODE_3D_SBS_3840_1080_90HZ },
  { label: "3D SBS 3840x1080 @ 120Hz", value: VITURE_NATIVE_DISPLAY_MODE_3D_SBS_3840_1080_120HZ },
  { label: "3D SBS 3840x1200 @ 60Hz", value: VITURE_NATIVE_DISPLAY_MODE_3D_SBS_3840_1200_60HZ },
  { label: "3D SBS 3840x1200 @ 90Hz", value: VITURE_NATIVE_DISPLAY_MODE_3D_SBS_3840_1200_90HZ },
  { label: "3D SBS 3840x1200 @ 120Hz", value: VITURE_NATIVE_DISPLAY_MODE_3D_SBS_3840_1200_120HZ },
  { label: "Ultrawide 3840x1080 @ 60Hz", value: VITURE_NATIVE_DISPLAY_MODE_ULTRAWIDE_3840_1080_60HZ },
  { label: "Ultrawide 3840x1080 @ 90Hz", value: VITURE_NATIVE_DISPLAY_MODE_ULTRAWIDE_3840_1080_90HZ },
  { label: "Ultrawide 3840x1080 @ 120Hz", value: VITURE_NATIVE_DISPLAY_MODE_ULTRAWIDE_3840_1080_120HZ },
  { label: "Ultrawide 3840x1200 @ 60Hz", value: VITURE_NATIVE_DISPLAY_MODE_ULTRAWIDE_3840_1200_60HZ },
  { label: "Ultrawide 3840x1200 @ 90Hz", value: VITURE_NATIVE_DISPLAY_MODE_ULTRAWIDE_3840_1200_90HZ },
  { label: "Ultrawide 3840x1200 @ 120Hz", value: VITURE_NATIVE_DISPLAY_MODE_ULTRAWIDE_3840_1200_120HZ }
];
var VITURE_NATIVE_DOF_0 = 0;
var VITURE_NATIVE_DOF_3 = 1;
var VITURE_NATIVE_DOF_SMOOTH_FOLLOW = 2;
var VITURE_DUTY_CYCLE_H = 98;
var VITURE_DUTY_CYCLE_M = 42;
var VITURE_DUTY_CYCLE_L = 30;
var VITURE_IMU_MODE_RAW = 0;
var VITURE_IMU_MODE_POSE = 1;
var VITURE_IMU_FREQUENCY_LOW = 0;
var VITURE_IMU_FREQUENCY_MEDIUM_LOW = 1;
var VITURE_IMU_FREQUENCY_MEDIUM = 2;
var VITURE_IMU_FREQUENCY_MEDIUM_HIGH = 3;
var VITURE_IMU_FREQUENCY_HIGH = 4;
var VITURE_IMU_FREQUENCY_ULTRA_HIGH = 5;
var VITURE_GLASSES_SUCCESS = 0;
var VITURE_GLASSES_ERROR_INVALID_PARAM = -1;
var VITURE_GLASSES_ERROR_USB_UNAVAILABLE = -2;
var VITURE_GLASSES_ERROR_USB_EXEC = -3;
var VITURE_GLASSES_ERROR_NOT_SUPPORTED = -4;
var VITURE_GLASSES_ERROR_NO_DATA = -5;
var VITURE_GLASSES_ERROR_DATA_PARSE = -6;
var VITURE_GLASSES_ERROR_DEVICE_REJECTED = -7;
var VITURE_GLASSES_ERROR_CALIB_INIT = -8;
var VITURE_GLASSES_ERROR_SERIAL_FETCH = -9;
var VITURE_GLASSES_ERROR_INVALID_STATE = -10;
var VITURE_GLASSES_ERROR_UNKNOWN = -99;
var XR_DEVICE_TYPE_GEN1 = 0;
var XR_DEVICE_TYPE_GEN2 = 1;
var XR_DEVICE_TYPE_CARINA = 2;
var VITURE_CALLBACK_ID_BRIGHTNESS = 0;
var VITURE_CALLBACK_ID_VOLUME = 1;
var VITURE_CALLBACK_ID_DISPLAY_MODE = 2;
var VITURE_CALLBACK_ID_ELECTROCHROMIC_FILM = 3;
var VITURE_CALLBACK_ID_NATIVE_DOF = 4;
var VITURE_CALLBACK_ID_WEAR_STATUS = 5;

// dist/intermediate/GlassesDevice.js
var GlassesDevice = class {
  mod;
  bridge;
  handle = 0;
  _isConnected = false;
  _productId = 0;
  _productName = "";
  _deviceType = -1;
  _supportsNativeDof = false;
  _poseRunning = false;
  _rawRunning = false;
  _stateRunning = false;
  _stateCb = null;
  constructor(mod) {
    this.mod = mod;
    this.bridge = new WebHidBridge(mod);
  }
  get isConnected() {
    return this._isConnected;
  }
  get productName() {
    return this._productName;
  }
  get deviceType() {
    return this._deviceType;
  }
  get supportsNativeDof() {
    return this._supportsNativeDof;
  }
  /**
   * Check whether the connected product supports the given IMU report
   * frequency (VITURE_IMU_FREQUENCY_*) in the given IMU mode
   * (VITURE_IMU_MODE_*). Frequency support can differ between raw and pose
   * modes on some products. Returns false when disconnected.
   */
  supportsImuFrequency(frequency, mode) {
    return this.mod.ccall("xr_device_provider_is_product_support_imu_frequency", "number", ["number", "number", "number"], [this._productId, mode, frequency]) !== 0;
  }
  /**
   * Open a Viture device. Must be called from inside a user-gesture handler
   * (click, keydown, etc.) because navigator.hid.requestDevice() requires it.
   */
  async connect() {
    await this.bridge.connect();
    this.handle = this.bridge.getHandle();
    this._isConnected = true;
    this._productId = this.bridge.getProductId();
    this._productName = this._fetchProductName();
    this._deviceType = this.mod.ccall("xr_device_provider_get_device_type", "number", ["number"], [this.handle]);
    this._supportsNativeDof = this.mod.ccall("xr_device_provider_is_product_support_native_dof", "number", ["number"], [this._productId]) !== 0;
    this.mod.ccall("xr_webhid_register_state_callback", null, ["number"], [this.handle]);
  }
  async disconnect() {
    if (!this._isConnected)
      return;
    await this.offPose();
    await this.offRaw();
    this.offStateChange();
    await this.bridge.disconnect();
    this.handle = 0;
    this._isConnected = false;
    this._productId = 0;
    this._productName = "";
    this._deviceType = -1;
    this._supportsNativeDof = false;
  }
  // -------------------------------------------------------------------------
  // SDK version (no device required)
  // -------------------------------------------------------------------------
  /** Returns the libglasses SDK version string (e.g. "2.3.1"). */
  sdkVersion() {
    const ptr = this.mod.ccall("GetVersionString", "number", [], []);
    return this.mod.UTF8ToString(ptr);
  }
  // -------------------------------------------------------------------------
  // Log level (global, no device required)
  // -------------------------------------------------------------------------
  setLogLevel(level) {
    this.mod.ccall("xr_device_provider_set_log_level", null, ["number"], [level]);
  }
  getLogLevel() {
    return this.mod.ccall("xr_device_provider_get_log_level", "number", [], []);
  }
  // -------------------------------------------------------------------------
  // Device info (require connection)
  // -------------------------------------------------------------------------
  /** Read the glasses firmware version string (e.g. "3.2.1"). */
  async getGlassesVersion() {
    this._requireConnected();
    const BUF_LEN = 64;
    const resBuf = this.mod._malloc(BUF_LEN);
    const lenBuf = this.mod._malloc(4);
    this.mod.setValue(lenBuf, BUF_LEN, "i32");
    try {
      const ret = await this.mod.ccall("xr_device_provider_get_glasses_version", "number", ["number", "number", "number"], [this.handle, resBuf, lenBuf]);
      if (ret !== VITURE_GLASSES_SUCCESS)
        throw new Error(`getGlassesVersion failed (ret=${ret})`);
      return this.mod.UTF8ToString(resBuf);
    } finally {
      this.mod._free(resBuf);
      this.mod._free(lenBuf);
    }
  }
  /** Read the glasses SN hash (SHA-256 of serial number), returned as a 64-char hex string. */
  async getSnHash() {
    this._requireConnected();
    const buf = this.mod._malloc(32);
    try {
      const ret = await this.mod.ccall("xr_device_provider_get_sn_hash", "number", ["number", "number"], [this.handle, buf]);
      if (ret !== VITURE_GLASSES_SUCCESS)
        throw new Error(`getSnHash failed (ret=${ret})`);
      const bytes = new Uint8Array(this.mod.HEAPU8.buffer, buf, 32);
      return Array.from(bytes).map((b) => b.toString(16).padStart(2, "0")).join("");
    } finally {
      this.mod._free(buf);
    }
  }
  // -------------------------------------------------------------------------
  // Device control
  // -------------------------------------------------------------------------
  /**
   * Set the electrochromic film tint level.
   * @param voltage  Tint in [0.0, 1.0].  0.0 = clear, 1.0 = dark.
   */
  async setFilmMode(voltage) {
    this._requireConnected();
    const ret = await this.mod.ccall("xr_device_provider_set_film_mode", "number", ["number", "number"], [this.handle, voltage]);
    if (ret !== VITURE_GLASSES_SUCCESS)
      throw new Error(`setFilmMode failed (ret=${ret})`);
  }
  /**
   * Get the current electrochromic film tint level.
   * @returns Voltage in [0.0, 1.0].
   */
  async getFilmMode() {
    this._requireConnected();
    const ptr = this.mod._malloc(4);
    try {
      const ret = await this.mod.ccall("xr_device_provider_get_film_mode", "number", ["number", "number"], [this.handle, ptr]);
      if (ret !== VITURE_GLASSES_SUCCESS)
        throw new Error(`getFilmMode failed (ret=${ret})`);
      return this.mod.getValue(ptr, "float");
    } finally {
      this.mod._free(ptr);
    }
  }
  /**
   * Get the current wear status (Gen2 devices only).
   * Wear status changes are also delivered via onStateChange with
   * VITURE_CALLBACK_ID_WEAR_STATUS.
   * @returns 0 = not worn, 1 = worn.
   */
  async getWearStatus() {
    this._requireConnected();
    const ptr = this.mod._malloc(1);
    try {
      const ret = await this.mod.ccall("xr_device_provider_get_wear_status", "number", ["number", "number"], [this.handle, ptr]);
      if (ret !== VITURE_GLASSES_SUCCESS)
        throw new Error(`getWearStatus failed (ret=${ret})`);
      return this.mod.getValue(ptr, "i8") & 255;
    } finally {
      this.mod._free(ptr);
    }
  }
  async getDisplayMode() {
    this._requireConnected();
    const ret = await this.mod.ccall("xr_device_provider_get_display_mode", "number", ["number"], [this.handle]);
    if (ret < 0)
      throw new Error(`getDisplayMode failed (ret=${ret})`);
    return ret;
  }
  async setDisplayMode(mode) {
    this._requireConnected();
    const ret = await this.mod.ccall("xr_device_provider_set_display_mode", "number", ["number", "number"], [this.handle, mode]);
    if (ret !== VITURE_GLASSES_SUCCESS)
      throw new Error(`setDisplayMode failed (ret=${ret})`);
  }
  async getBrightness() {
    this._requireConnected();
    const ret = await this.mod.ccall("xr_device_provider_get_brightness_level", "number", ["number"], [this.handle]);
    if (ret < 0)
      throw new Error(`getBrightness failed (ret=${ret})`);
    return ret;
  }
  async setBrightness(level) {
    this._requireConnected();
    const ret = await this.mod.ccall("xr_device_provider_set_brightness_level", "number", ["number", "number"], [this.handle, level]);
    if (ret !== VITURE_GLASSES_SUCCESS)
      throw new Error(`setBrightness failed (ret=${ret})`);
  }
  async getVolume() {
    this._requireConnected();
    const ret = await this.mod.ccall("xr_device_provider_get_volume_level", "number", ["number"], [this.handle]);
    if (ret < 0)
      throw new Error(`getVolume failed (ret=${ret})`);
    return ret;
  }
  async setVolume(level) {
    this._requireConnected();
    const ret = await this.mod.ccall("xr_device_provider_set_volume_level", "number", ["number", "number"], [this.handle, level]);
    if (ret !== VITURE_GLASSES_SUCCESS)
      throw new Error(`setVolume failed (ret=${ret})`);
  }
  async switchDimension(is3d) {
    this._requireConnected();
    const ret = await this.mod.ccall("xr_device_provider_switch_dimension", "number", ["number", "number"], [this.handle, is3d ? 1 : 0]);
    if (ret !== VITURE_GLASSES_SUCCESS)
      throw new Error(`switchDimension failed (ret=${ret})`);
  }
  /** Get the duty cycle value (device-specific range). */
  async getDutyCycle() {
    this._requireConnected();
    const ret = await this.mod.ccall("xr_device_provider_get_duty_cycle", "number", ["number"], [this.handle]);
    if (ret < 0)
      throw new Error(`getDutyCycle failed (ret=${ret})`);
    return ret;
  }
  /** Set the duty cycle value (device-specific range). */
  async setDutyCycle(dutyCycle) {
    this._requireConnected();
    const ret = await this.mod.ccall("xr_device_provider_set_duty_cycle", "number", ["number", "number"], [this.handle, dutyCycle]);
    if (ret !== VITURE_GLASSES_SUCCESS)
      throw new Error(`setDutyCycle failed (ret=${ret})`);
  }
  // -------------------------------------------------------------------------
  // Native DOF device control (Beast)
  // -------------------------------------------------------------------------
  /** Get the native operating mode: 0 = bypass, 1 = native DOF. */
  async nativeGetMode() {
    this._requireConnected();
    const ret = await this.mod.ccall("xr_device_provider_native_get_mode", "number", ["number"], [this.handle]);
    if (ret < 0)
      throw new Error(`nativeGetMode failed (ret=${ret})`);
    return ret;
  }
  /** Set the native operating mode: 0 = bypass, 1 = native DOF. */
  async nativeSetMode(mode) {
    this._requireConnected();
    const ret = await this.mod.ccall("xr_device_provider_native_set_mode", "number", ["number", "number"], [this.handle, mode]);
    if (ret !== VITURE_GLASSES_SUCCESS)
      throw new Error(`nativeSetMode failed (ret=${ret})`);
  }
  /** Get the native-mode display mode (VITURE_NATIVE_DISPLAY_MODE_*). */
  async nativeGetDisplayMode() {
    this._requireConnected();
    const ret = await this.mod.ccall("xr_device_provider_native_get_display_mode", "number", ["number"], [this.handle]);
    if (ret < 0)
      throw new Error(`nativeGetDisplayMode failed (ret=${ret})`);
    return ret;
  }
  /** Set the native-mode display mode (VITURE_NATIVE_DISPLAY_MODE_*). */
  async nativeSetDisplayMode(mode) {
    this._requireConnected();
    const ret = await this.mod.ccall("xr_device_provider_native_set_display_mode", "number", ["number", "number"], [this.handle, mode]);
    if (ret !== VITURE_GLASSES_SUCCESS)
      throw new Error(`nativeSetDisplayMode failed (ret=${ret})`);
  }
  /** Get the DOF tracking type (VITURE_NATIVE_DOF_*). */
  async nativeGetDof() {
    this._requireConnected();
    const ret = await this.mod.ccall("xr_device_provider_native_get_dof", "number", ["number"], [this.handle]);
    if (ret < 0)
      throw new Error(`nativeGetDof failed (ret=${ret})`);
    return ret;
  }
  /** Set the DOF tracking type (VITURE_NATIVE_DOF_*). */
  async nativeSetDof(dof) {
    this._requireConnected();
    const ret = await this.mod.ccall("xr_device_provider_native_set_dof", "number", ["number", "number"], [this.handle, dof]);
    if (ret !== VITURE_GLASSES_SUCCESS)
      throw new Error(`nativeSetDof failed (ret=${ret})`);
  }
  /** Recenter the DOF tracking origin to the current head orientation. */
  async nativeRecenterDof() {
    this._requireConnected();
    const ret = await this.mod.ccall("xr_device_provider_native_recenter_dof", "number", ["number"], [this.handle]);
    if (ret !== VITURE_GLASSES_SUCCESS)
      throw new Error(`nativeRecenterDof failed (ret=${ret})`);
  }
  /** Switch 2D/3D in native DOF mode. */
  async nativeSwitchDimension(is3d) {
    this._requireConnected();
    const ret = await this.mod.ccall("xr_device_provider_native_switch_dimension", "number", ["number", "number"], [this.handle, is3d ? 1 : 0]);
    if (ret !== VITURE_GLASSES_SUCCESS)
      throw new Error(`nativeSwitchDimension failed (ret=${ret})`);
  }
  /** Get side mode: 0 = off, 1 = on. */
  async nativeGetSideMode() {
    this._requireConnected();
    const ret = await this.mod.ccall("xr_device_provider_native_get_side_mode", "number", ["number"], [this.handle]);
    if (ret < 0)
      throw new Error(`nativeGetSideMode failed (ret=${ret})`);
    return ret;
  }
  /** Set side mode: 0 = off, 1 = on. */
  async nativeSetSideMode(value) {
    this._requireConnected();
    const ret = await this.mod.ccall("xr_device_provider_native_set_side_mode", "number", ["number", "number"], [this.handle, value]);
    if (ret !== VITURE_GLASSES_SUCCESS)
      throw new Error(`nativeSetSideMode failed (ret=${ret})`);
  }
  /** Get the virtual display distance (1–10). */
  async nativeGetDisplayDistance() {
    this._requireConnected();
    const ret = await this.mod.ccall("xr_device_provider_native_get_display_distance", "number", ["number"], [this.handle]);
    if (ret < 0)
      throw new Error(`nativeGetDisplayDistance failed (ret=${ret})`);
    return ret;
  }
  /** Set the virtual display distance (1–10). */
  async nativeSetDisplayDistance(distance) {
    this._requireConnected();
    const ret = await this.mod.ccall("xr_device_provider_native_set_display_distance", "number", ["number", "number"], [this.handle, distance]);
    if (ret !== VITURE_GLASSES_SUCCESS)
      throw new Error(`nativeSetDisplayDistance failed (ret=${ret})`);
  }
  /** Get the virtual display size index (0=Small … 4=Ultra). */
  async nativeGetDisplaySize() {
    this._requireConnected();
    const ret = await this.mod.ccall("xr_device_provider_native_get_display_size", "number", ["number"], [this.handle]);
    if (ret < 0)
      throw new Error(`nativeGetDisplaySize failed (ret=${ret})`);
    return ret;
  }
  /** Set the virtual display size index (0=Small … 4=Ultra). */
  async nativeSetDisplaySize(size) {
    this._requireConnected();
    const ret = await this.mod.ccall("xr_device_provider_native_set_display_size", "number", ["number", "number"], [this.handle, size]);
    if (ret !== VITURE_GLASSES_SUCCESS)
      throw new Error(`nativeSetDisplaySize failed (ret=${ret})`);
  }
  // -------------------------------------------------------------------------
  // IMU streaming
  // -------------------------------------------------------------------------
  /**
   * Start IMU pose streaming.  The callback fires on every animation frame
   * with the latest pose from the C++ IMU thread.
   *
   * @param cb         Called with the latest ImuPose on each rAF tick.
   * @param frequency  Device report rate (VITURE_IMU_FREQUENCY_*). Default: 120 Hz.
   */
  async onPose(cb, frequency = VITURE_IMU_FREQUENCY_MEDIUM) {
    this._requireConnected();
    if (this._poseRunning)
      return;
    const ret = await this.mod.ccall("xr_device_provider_open_imu", "number", ["number", "number", "number"], [this.handle, VITURE_IMU_MODE_POSE, frequency]);
    if (ret !== VITURE_GLASSES_SUCCESS)
      throw new Error(`open_imu(POSE) failed (ret=${ret})`);
    this.mod.ccall("xr_webhid_register_imu_pose_callback", null, ["number"], [this.handle]);
    const ptr = this.mod.ccall("xr_webhid_get_pose_ptr", "number", [], []);
    this._poseRunning = true;
    const loop = () => {
      if (!this._poseRunning)
        return;
      const f32 = new Float32Array(this.mod.HEAPU8.buffer, ptr, 7);
      cb({
        roll: f32[0],
        pitch: f32[1],
        yaw: f32[2],
        qw: f32[3],
        qx: f32[4],
        qy: f32[5],
        qz: f32[6]
      });
      requestAnimationFrame(loop);
    };
    requestAnimationFrame(loop);
  }
  /** Stop IMU pose streaming. */
  async offPose() {
    if (!this._poseRunning)
      return;
    this._poseRunning = false;
    if (this._isConnected && this.handle) {
      await this.mod.ccall("xr_device_provider_close_imu", "number", ["number", "number"], [this.handle, VITURE_IMU_MODE_POSE]);
    }
  }
  /**
   * Start raw IMU sensor streaming.  The callback fires on every animation
   * frame with the latest sample from the C++ IMU thread.
   *
   * @param cb         Called with the latest ImuRaw on each rAF tick.
   * @param frequency  Device report rate (VITURE_IMU_FREQUENCY_*). Default: 120 Hz.
   */
  async onRaw(cb, frequency = VITURE_IMU_FREQUENCY_MEDIUM) {
    this._requireConnected();
    if (this._rawRunning)
      return;
    const ret = await this.mod.ccall("xr_device_provider_open_imu", "number", ["number", "number", "number"], [this.handle, VITURE_IMU_MODE_RAW, frequency]);
    if (ret !== VITURE_GLASSES_SUCCESS)
      throw new Error(`open_imu(RAW) failed (ret=${ret})`);
    this.mod.ccall("xr_webhid_register_imu_raw_callback", null, ["number"], [this.handle]);
    const ptr = this.mod.ccall("xr_webhid_get_raw_ptr", "number", [], []);
    this._rawRunning = true;
    const loop = () => {
      if (!this._rawRunning)
        return;
      const f32 = new Float32Array(this.mod.HEAPU8.buffer, ptr, 10);
      const u32 = new Uint32Array(this.mod.HEAPU8.buffer, ptr + 40, 4);
      cb({
        gyroX: f32[0],
        gyroY: f32[1],
        gyroZ: f32[2],
        accelX: f32[3],
        accelY: f32[4],
        accelZ: f32[5],
        magX: f32[6],
        magY: f32[7],
        magZ: f32[8],
        temperature: f32[9],
        timestamp: BigInt(u32[1]) << 32n | BigInt(u32[0]),
        vsync: BigInt(u32[3]) << 32n | BigInt(u32[2])
      });
      requestAnimationFrame(loop);
    };
    requestAnimationFrame(loop);
  }
  /** Stop raw IMU streaming. */
  async offRaw() {
    if (!this._rawRunning)
      return;
    this._rawRunning = false;
    if (this._isConnected && this.handle) {
      await this.mod.ccall("xr_device_provider_close_imu", "number", ["number", "number"], [this.handle, VITURE_IMU_MODE_RAW]);
    }
  }
  // -------------------------------------------------------------------------
  // Hardware state change notifications
  // -------------------------------------------------------------------------
  /**
   * Subscribe to hardware state change events (brightness, volume, display
   * mode, electrochromic film, native DOF).  The callback fires on each rAF
   * tick when the device has reported a change.
   *
   * id is one of the VITURE_CALLBACK_ID_* constants; value is the new setting.
   */
  onStateChange(cb) {
    this._requireConnected();
    this._stateCb = cb;
    if (this._stateRunning)
      return;
    this._stateRunning = true;
    const loop = () => {
      if (!this._stateRunning)
        return;
      const packed = this.mod.ccall("xr_webhid_poll_state_change", "number", [], []);
      if (packed !== -1) {
        const id = packed >>> 24 & 255;
        const value = packed & 16777215;
        this._stateCb?.(id, value);
      }
      requestAnimationFrame(loop);
    };
    requestAnimationFrame(loop);
  }
  /** Unsubscribe from hardware state change events. */
  offStateChange() {
    this._stateRunning = false;
    this._stateCb = null;
  }
  // -------------------------------------------------------------------------
  // Private
  // -------------------------------------------------------------------------
  _requireConnected() {
    if (!this._isConnected)
      throw new Error("GlassesDevice: not connected");
  }
  _fetchProductName() {
    const pid = this.bridge.getProductId();
    const BUF_LEN = 128;
    const nameBuf = this.mod._malloc(BUF_LEN);
    const lenBuf = this.mod._malloc(4);
    this.mod.setValue(lenBuf, BUF_LEN, "i32");
    const ret = this.mod.ccall("xr_device_provider_get_market_name", "number", ["number", "number", "number"], [pid, nameBuf, lenBuf]);
    const name = ret === 0 ? this.mod.UTF8ToString(nameBuf) : "";
    this.mod._free(nameBuf);
    this.mod._free(lenBuf);
    return name;
  }
};
export {
  DISPLAY_MODES,
  GlassesDevice,
  NATIVE_DISPLAY_MODES,
  VITURE_CALLBACK_ID_BRIGHTNESS,
  VITURE_CALLBACK_ID_DISPLAY_MODE,
  VITURE_CALLBACK_ID_ELECTROCHROMIC_FILM,
  VITURE_CALLBACK_ID_NATIVE_DOF,
  VITURE_CALLBACK_ID_VOLUME,
  VITURE_CALLBACK_ID_WEAR_STATUS,
  VITURE_DISPLAY_MODE_1920_1080_120HZ,
  VITURE_DISPLAY_MODE_1920_1080_60HZ,
  VITURE_DISPLAY_MODE_1920_1080_90HZ,
  VITURE_DISPLAY_MODE_1920_1200_120HZ,
  VITURE_DISPLAY_MODE_1920_1200_60HZ,
  VITURE_DISPLAY_MODE_1920_1200_90HZ,
  VITURE_DISPLAY_MODE_3840_1080_60HZ,
  VITURE_DISPLAY_MODE_3840_1080_90HZ,
  VITURE_DISPLAY_MODE_3840_1200_60HZ,
  VITURE_DISPLAY_MODE_3840_1200_90HZ,
  VITURE_DUTY_CYCLE_H,
  VITURE_DUTY_CYCLE_L,
  VITURE_DUTY_CYCLE_M,
  VITURE_GLASSES_ERROR_CALIB_INIT,
  VITURE_GLASSES_ERROR_DATA_PARSE,
  VITURE_GLASSES_ERROR_DEVICE_REJECTED,
  VITURE_GLASSES_ERROR_INVALID_PARAM,
  VITURE_GLASSES_ERROR_INVALID_STATE,
  VITURE_GLASSES_ERROR_NOT_SUPPORTED,
  VITURE_GLASSES_ERROR_NO_DATA,
  VITURE_GLASSES_ERROR_SERIAL_FETCH,
  VITURE_GLASSES_ERROR_UNKNOWN,
  VITURE_GLASSES_ERROR_USB_EXEC,
  VITURE_GLASSES_ERROR_USB_UNAVAILABLE,
  VITURE_GLASSES_SUCCESS,
  VITURE_IMU_FREQUENCY_HIGH,
  VITURE_IMU_FREQUENCY_LOW,
  VITURE_IMU_FREQUENCY_MEDIUM,
  VITURE_IMU_FREQUENCY_MEDIUM_HIGH,
  VITURE_IMU_FREQUENCY_MEDIUM_LOW,
  VITURE_IMU_FREQUENCY_ULTRA_HIGH,
  VITURE_IMU_MODE_POSE,
  VITURE_IMU_MODE_RAW,
  VITURE_NATIVE_DISPLAY_MODE_1920_1080_120HZ,
  VITURE_NATIVE_DISPLAY_MODE_1920_1080_60HZ,
  VITURE_NATIVE_DISPLAY_MODE_1920_1080_90HZ,
  VITURE_NATIVE_DISPLAY_MODE_1920_1200_120HZ,
  VITURE_NATIVE_DISPLAY_MODE_1920_1200_60HZ,
  VITURE_NATIVE_DISPLAY_MODE_1920_1200_90HZ,
  VITURE_NATIVE_DISPLAY_MODE_3D_SBS_3840_1080_120HZ,
  VITURE_NATIVE_DISPLAY_MODE_3D_SBS_3840_1080_60HZ,
  VITURE_NATIVE_DISPLAY_MODE_3D_SBS_3840_1080_90HZ,
  VITURE_NATIVE_DISPLAY_MODE_3D_SBS_3840_1200_120HZ,
  VITURE_NATIVE_DISPLAY_MODE_3D_SBS_3840_1200_60HZ,
  VITURE_NATIVE_DISPLAY_MODE_3D_SBS_3840_1200_90HZ,
  VITURE_NATIVE_DISPLAY_MODE_ULTRAWIDE_3840_1080_120HZ,
  VITURE_NATIVE_DISPLAY_MODE_ULTRAWIDE_3840_1080_60HZ,
  VITURE_NATIVE_DISPLAY_MODE_ULTRAWIDE_3840_1080_90HZ,
  VITURE_NATIVE_DISPLAY_MODE_ULTRAWIDE_3840_1200_120HZ,
  VITURE_NATIVE_DISPLAY_MODE_ULTRAWIDE_3840_1200_60HZ,
  VITURE_NATIVE_DISPLAY_MODE_ULTRAWIDE_3840_1200_90HZ,
  VITURE_NATIVE_DOF_0,
  VITURE_NATIVE_DOF_3,
  VITURE_NATIVE_DOF_SMOOTH_FOLLOW,
  VITURE_VID,
  XR_DEVICE_TYPE_CARINA,
  XR_DEVICE_TYPE_GEN1,
  XR_DEVICE_TYPE_GEN2
};
