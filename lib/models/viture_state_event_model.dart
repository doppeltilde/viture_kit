class VitureStateEvent {
  final int stateId;
  final int value;

  VitureStateEvent(this.stateId, this.value);

  @override
  String toString() => 'VitureStateEvent(id: $stateId, value: $value)';
}
