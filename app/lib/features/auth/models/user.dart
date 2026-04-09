import 'package:freezed_annotation/freezed_annotation.dart';

part 'user.freezed.dart';
part 'user.g.dart';

@freezed
class User with _$User {
  const factory User({
    required int id,
    required String username,
    required String name,
    required String email,
    @JsonKey(name: 'is_authenticated') required bool isAuthenticated,
    @JsonKey(name: 'is_anonymous') required bool isAnonymous,
  }) = _User;

  factory User.fromJson(Map<String, dynamic> json) => _$UserFromJson(json);
}
