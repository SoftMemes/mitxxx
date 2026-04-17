enum Flavor { dev, prod }

class FlavorConfig {
  static Flavor? _flavor;

  static Flavor get flavor {
    assert(
      _flavor != null,
      'FlavorConfig.flavor must be set before being read',
    );
    return _flavor!;
  }

  static set flavor(Flavor value) => _flavor = value;

  static bool get isDev => flavor == Flavor.dev;
  static bool get isProd => flavor == Flavor.prod;
}
