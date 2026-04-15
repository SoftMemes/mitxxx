import 'package:omnilect/flavor_config.dart';
import 'package:omnilect/main.dart';

void main() {
  FlavorConfig.set(Flavor.prod);
  bootstrap();
}
