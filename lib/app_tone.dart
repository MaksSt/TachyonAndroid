enum AppTone {
  red('Красный', 0xffa74443, 0xffd58d87),
  orange('Оранжевый', 0xffb96317, 0xffeaa160),
  blue('Синий', 0xff2762a5, 0xff8eb9e8),
  green('Зелёный', 0xff35724a, 0xff91cba0);

  const AppTone(this.label, this.lightSeed, this.darkSeed);
  final String label;
  final int lightSeed, darkSeed;

  static AppTone parse(Object? value) =>
      values.where((tone) => tone.name == value).firstOrNull ?? red;
}
