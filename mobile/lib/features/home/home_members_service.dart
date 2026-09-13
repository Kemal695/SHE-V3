// =============================================================================
// SHE V3 — Home members service (Riverpod provider)
// =============================================================================
// V3-API-SPECIFICATION §4 (homes/members).
//
// Server-side contract (backend/src/main/java/.../HomeServiceImpl.java):
//   roles are validated against ^(OWNER|ADMIN|MEMBER|GUEST)$ and there is a
//   privilege-escalation guard — only an OWNER may grant the OWNER role.
//   The backend rejects anything else with 400 VALIDATION_FAILED, so the UI
//   must only ever send one of these four values.
// =============================================================================

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/api_constants.dart';
import '../../core/network/dio_client.dart';

/// Roles accepted by the backend. Order matters only for display.
const List<String> kHomeRoles = <String>['OWNER', 'ADMIN', 'MEMBER', 'GUEST'];

final homeMembersServiceProvider =
    Provider<HomeMembersService>((ref) => HomeMembersService(ref));

class HomeMembersService {
  final Ref ref;
  HomeMembersService(this.ref);

  Dio get _dio => ref.read(dioProvider);

  /// GET /api/v3/homes/{homeId}/members
  Future<List<Map<String, dynamic>>> listMembers(String homeId) async {
    final response = await _dio.get(ApiConstants.homeMembers(homeId));
    return List<Map<String, dynamic>>.from(response.data['data']);
  }

  /// POST /api/v3/homes/{homeId}/members  — body {email, role}
  Future<Map<String, dynamic>> addMember(
    String homeId, {
    required String email,
    required String role,
  }) async {
    final response = await _dio.post(
      ApiConstants.homeMembers(homeId),
      data: {'email': email.trim(), 'role': role},
    );
    return response.data['data'];
  }

  /// PATCH /api/v3/homes/{homeId}/members/{userId} — body {role}
  Future<Map<String, dynamic>> updateMemberRole(
    String homeId,
    String userId, {
    required String role,
  }) async {
    final response = await _dio.patch(
      '${ApiConstants.homeMembers(homeId)}/$userId',
      data: {'role': role},
    );
    return response.data['data'];
  }

  /// DELETE /api/v3/homes/{homeId}/members/{userId}
  Future<void> removeMember(String homeId, String userId) async {
    await _dio.delete('${ApiConstants.homeMembers(homeId)}/$userId');
  }
}
