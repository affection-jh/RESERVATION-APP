import 'package:flutter/material.dart';

// ===== 데이터 모델 (더미) =====
class StoryData {
  final String title;
  final String content;
  final String date;
  final List<String> imageUrls;
  final String? backgroundImageUrl; // 배경 이미지 URL

  StoryData({
    required this.title,
    required this.content,
    required this.date,
    this.imageUrls = const [],
    this.backgroundImageUrl,
  });
}

class PromotionData {
  final String title;
  final String description;
  final String? tag;
  final String? imageUrl;
  final Color? backgroundColor;

  PromotionData({
    required this.title,
    required this.description,
    this.tag,
    this.imageUrl,
    this.backgroundColor,
  });
}

class HomeCourseData {
  final String title;
  final String instructor;
  final String description;
  final String? imageUrl;
  final String? price;
  final double? rating;
  final int? studentCount;

  HomeCourseData({
    required this.title,
    required this.instructor,
    required this.description,
    this.imageUrl,
    this.price,
    this.rating,
    this.studentCount,
  });
}

class MemberData {
  final String userId;
  final String name;
  final String phoneNumber;
  final String role;
  final bool isActive;
  final int pendingExtensionRequests; // 대기 중인 연장 요청 수
  final bool? needsReenrollment; // 재등록 필요 여부
  final List<String>? reenrollmentRequiredCourseIds; // 재등록이 필요한 코스 ID 리스트
  final List<String>? enrolledCourseIds; // 등록된 코스 ID 리스트

  MemberData({
    required this.userId,
    required this.name,
    required this.phoneNumber,
    required this.role,
    required this.isActive,
    this.pendingExtensionRequests = 0,
    this.needsReenrollment,
    this.reenrollmentRequiredCourseIds,
    this.enrolledCourseIds,
  });

  // 요청이 있는지 확인
  bool get hasPendingRequests {
    return pendingExtensionRequests > 0;
  }

  // 총 요청 수
  int get totalPendingRequests {
    return pendingExtensionRequests;
  }
}
