abstract class VitureDeviceType {
  static const int carina = 2;
}

enum VitureImuMode {
  raw(0),
  pose(1);

  final int value;
  const VitureImuMode(this.value);
}

enum VitureImuFrequency {
  freq60Hz(1),
  freq120Hz(2),
  freq240Hz(3);

  final int value;
  const VitureImuFrequency(this.value);
}

enum VitureStateId {
  brightness(0),
  volume(1),
  displayMode(2),
  electrochromicFilm(3),
  nativeDof(4),
  wearStatus(5);

  const VitureStateId(this.id);
  final int id;

  static VitureStateId? fromId(int id) {
    for (final type in VitureStateId.values) {
      if (type.id == id) return type;
    }
    return null;
  }
}
