enum Flavor { dev, prod }

class FlavorConfig {
  static Flavor? _flavor;

  static void set(Flavor flavor) {
    _flavor = flavor;
  }

  static Flavor get flavor {
    assert(
      _flavor != null,
      'FlavorConfig.set() must be called before accessing FlavorConfig.flavor',
    );
    return _flavor!;
  }

  static bool get isDev => flavor == Flavor.dev;
  static bool get isProd => flavor == Flavor.prod;
}
