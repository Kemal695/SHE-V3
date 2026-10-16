// =============================================================================
// SHE V3 — OTA service (firmware rollouts)
// =============================================================================
// V3-API-SPECIFICATION §9. Drive the design sheet's screen 17 (OTA Update).
//
// Domain, because it is not obvious from the endpoint list alone:
//
//   ota_batches     — ONE rollout: a firmware version + url + checksum +
//                     signature, targeting a SKU, with a status
//                     (DRAFT / APPROVED / ROLLING / COMPLETED / ABORTED / FAILED).
//   ota_approvals   — ONE ROW PER NODE in that batch, carrying that node's own
//                     status, deployment_status, progress 0-100 and last_error.
//
// So "is this device up to date?" is a per-NODE question, but the API only
// exposes a per-BATCH status plus an approval COUNT. That is why this service
// reads the approvals list — without it the UI can only show one opaque
// status for the whole rollout.
//
// Permissions follow §9: list/get are MEMBER, but start / abort / approve /
// decline require ADMIN+. The backend enforces this; the app should hide those
// controls for non-admins rather than letting them tap into a 403.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/api_constants.dart';
import '../../core/network/dio_client.dart';

final otaServiceProvider = Provider<OtaService>((ref) => OtaService(ref));

/// One OTA batch (a rollout of a firmware version to a SKU).
class OtaBatch {
  final String id;
  final String firmwareVersion;
  final String targetSku;
  final String status; // DRAFT APPROVED ROLLING COMPLETED ABORTED FAILED
  final int rolloutPercent;
  final bool autoApprove;
  final String? createdAt;
  final int approvalCount;

  const OtaBatch({
    required this.id,
    required this.firmwareVersion,
    required this.targetSku,
    required this.status,
    required this.rolloutPercent,
    required this.autoApprove,
    this.createdAt,
    required this.approvalCount,
  });

  factory OtaBatch.fromJson(Map<String, dynamic> j) => OtaBatch(
        id: (j['id'] ?? '').toString(),
        firmwareVersion: (j['firmware_version'] ?? '').toString(),
        targetSku: (j['target_sku'] ?? '').toString(),
        status: (j['status'] ?? 'DRAFT').toString(),
        rolloutPercent: (j['rollout_percent'] as num?)?.toInt() ?? 100,
        autoApprove: j['auto_approve'] == true,
        createdAt: j['created_at']?.toString(),
        approvalCount: (j['approval_count'] as num?)?.toInt() ?? 0,
      );

  bool get isRolling => status == 'ROLLING';
  bool get isFinished =>
      status == 'COMPLETED' || status == 'ABORTED' || status == 'FAILED';
}

/// One node's slice of a rollout.
class OtaApproval {
  final String id;
  final String batchId;
  final String nodeId;
  final String status; // PENDING APPROVED DECLINED IN_PROGRESS COMPLETED
                       // ROLLED_BACK FAILED
  final String? deploymentStatus; // DOWNLOADING / FLASHING / ...
  final int progress; // 0-100
  final String? lastError;

  const OtaApproval({
    required this.id,
    required this.batchId,
    required this.nodeId,
    required this.status,
    this.deploymentStatus,
    required this.progress,
    this.lastError,
  });

  factory OtaApproval.fromJson(Map<String, dynamic> j) => OtaApproval(
        id: (j['id'] ?? '').toString(),
        batchId: (j['batch_id'] ?? '').toString(),
        nodeId: (j['node_id'] ?? '').toString(),
        status: (j['status'] ?? 'PENDING').toString(),
        deploymentStatus: j['deployment_status']?.toString(),
        progress: (j['progress'] as num?)?.toInt() ?? 0,
        lastError: j['last_error']?.toString(),
      );

  bool get isPending => status == 'PENDING';
  bool get isFailed => status == 'FAILED' || status == 'ROLLED_BACK';
  bool get isDone => status == 'COMPLETED';
}

class OtaService {
  final Ref ref;
  OtaService(this.ref);

  dynamic get _dio => ref.read(dioProvider);

  Future<List<OtaBatch>> listBatches(String homeId) async {
    final r = await _dio.get(ApiConstants.otaBatches(homeId));
    final list = r.data['data'] as List<dynamic>? ?? const [];
    return list
        .map((e) => OtaBatch.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<OtaBatch> getBatch(String batchId) async {
    final r = await _dio.get(ApiConstants.otaBatch(batchId));
    return OtaBatch.fromJson(Map<String, dynamic>.from(r.data['data'] as Map));
  }

  /// Per-node progress for a batch — the only way to show WHICH node is at
  /// what stage. Added to the backend 2026-10-08 for this screen.
  Future<List<OtaApproval>> listApprovals(String batchId) async {
    final r = await _dio.get(ApiConstants.otaBatchApprovals(batchId));
    final list = r.data['data'] as List<dynamic>? ?? const [];
    return list
        .map((e) => OtaApproval.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// ADMIN+. Creates PENDING approvals for matching nodes and publishes the
  /// ota/url to each device.
  Future<void> startBatch(String batchId) async {
    await _dio.post(ApiConstants.otaBatchStart(batchId));
  }

  /// ADMIN+.
  Future<void> abortBatch(String batchId) async {
    await _dio.post(ApiConstants.otaBatchAbort(batchId));
  }

  /// ADMIN+. Approve one node and push the firmware url to it.
  Future<OtaApproval> approve(String approvalId) async {
    final r = await _dio.post(ApiConstants.otaApprovalApprove(approvalId));
    return OtaApproval.fromJson(Map<String, dynamic>.from(r.data['data'] as Map));
  }

  /// ADMIN+.
  Future<OtaApproval> decline(String approvalId) async {
    final r = await _dio.post(ApiConstants.otaApprovalDecline(approvalId));
    return OtaApproval.fromJson(Map<String, dynamic>.from(r.data['data'] as Map));
  }
}
