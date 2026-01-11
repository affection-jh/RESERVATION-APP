import 'package:flutter/material.dart';

import '../models/course.dart' as reservation_models;
import '../models/place.dart';

@immutable
class HomeNotice {
  final String id;
  final String title;
  final String content;
  final String date; // "YYYY.MM.DD"
  final IconData icon;
  final Color? backgroundColor;

  const HomeNotice({
    required this.id,
    required this.title,
    required this.content,
    required this.date,
    required this.icon,
    this.backgroundColor,
  });
}

@immutable
class HomePromotion {
  final String id;
  final String title;
  final String description;
  final String? tag;
  final String? imageUrl;
  final Color? backgroundColor;

  const HomePromotion({
    required this.id,
    required this.title,
    required this.description,
    this.tag,
    this.imageUrl,
    this.backgroundColor,
  });
}

@immutable
class HomeRecommendedCourse {
  final String id;
  final String title;
  final String instructor;
  final String description;
  final String? imageUrl;
  final String? price;
  final double? rating;
  final int? studentCount;

  const HomeRecommendedCourse({
    required this.id,
    required this.title,
    required this.instructor,
    required this.description,
    this.imageUrl,
    this.price,
    this.rating,
    this.studentCount,
  });
}

enum MemberRole { user, admin }

@immutable
class Member {
  final String id;
  final String name;
  final String email;
  final MemberRole role;
  final bool isActive;

  const Member({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    required this.isActive,
  });

  Member copyWith({
    String? id,
    String? name,
    String? email,
    MemberRole? role,
    bool? isActive,
  }) {
    return Member(
      id: id ?? this.id,
      name: name ?? this.name,
      email: email ?? this.email,
      role: role ?? this.role,
      isActive: isActive ?? this.isActive,
    );
  }
}

class AppState extends ChangeNotifier {
  Place _place;
  final List<HomeNotice> _homeNotices;
  final List<HomePromotion> _homePromotions;
  final List<HomeRecommendedCourse> _homeRecommendedCourses;
  final List<Member> _members;

  AppState._({
    required Place place,
    required List<HomeNotice> homeNotices,
    required List<HomePromotion> homePromotions,
    required List<HomeRecommendedCourse> homeRecommendedCourses,
    required List<Member> members,
  }) : _place = place,
       _homeNotices = homeNotices,
       _homePromotions = homePromotions,
       _homeRecommendedCourses = homeRecommendedCourses,
       _members = members;

  factory AppState.initial() {
    final now = DateTime.now();
    String dateStr(DateTime d) =>
        '${d.year}.${d.month.toString().padLeft(2, '0')}.${d.day.toString().padLeft(2, '0')}';

    // TODO: Provider를 사용하므로 AppState는 더 이상 사용되지 않음
    // 필요시 삭제 고려
    return AppState._(
      place: Place(id: '', name: '', adminId: '', courses: []),
      homeNotices: [
        HomeNotice(
          id: 'notice_001',
          title: '새로운 기능이 추가되었습니다',
          content: '리퀘스트 작성 시 더 많은 옵션을 사용할 수 있습니다.',
          date: dateStr(DateTime(now.year, 1, 15)),
          icon: Icons.notifications,
        ),
        HomeNotice(
          id: 'notice_002',
          title: '서비스 점검 안내',
          content: '1월 20일 새벽 2시부터 4시까지 서비스 점검이 진행됩니다.',
          date: dateStr(DateTime(now.year, 1, 10)),
          icon: Icons.info,
          backgroundColor: const Color(0xFFE3F2FD),
        ),
        HomeNotice(
          id: 'notice_003',
          title: '이벤트 안내',
          content: '첫 리퀘스트 작성 시 경험치 100점을 드립니다!',
          date: dateStr(DateTime(now.year, 1, 5)),
          icon: Icons.celebration,
          backgroundColor: const Color(0xFFFFF3E0),
        ),
      ],
      homePromotions: const [
        HomePromotion(
          id: 'promo_001',
          title: '신규 코스 오픈!',
          description: '프로그래밍 기초부터 실전까지! 체계적인 커리큘럼으로 여러분의 성장을 도와드립니다.',
          tag: '신규',
        ),
        HomePromotion(
          id: 'promo_002',
          title: '특별 이벤트 진행중',
          description: '지금 신청하면 50% 할인! 제한된 수강생만을 위한 특별 혜택을 놓치지 마세요.',
          tag: '이벤트',
        ),
        HomePromotion(
          id: 'promo_003',
          title: '성공 스토리',
          description: '수강생들의 실제 후기와 성공 사례를 확인해보세요. 여러분도 함께 성장할 수 있습니다.',
          tag: '스토리',
        ),
      ],
      homeRecommendedCourses: const [
        HomeRecommendedCourse(
          id: 'hc_001',
          title: 'Flutter 앱 개발 마스터',
          instructor: '김개발',
          description: 'Flutter를 활용한 크로스 플랫폼 앱 개발을 배워보세요. 실전 프로젝트와 함께 진행합니다.',
          price: '₩99,000',
          rating: 4.8,
          studentCount: 1250,
        ),
        HomeRecommendedCourse(
          id: 'hc_002',
          title: 'React 완전 정복',
          instructor: '이프론트',
          description: 'React의 기초부터 고급 패턴까지, 실무에서 바로 사용할 수 있는 스킬을 배웁니다.',
          price: '₩89,000',
          rating: 4.9,
          studentCount: 2100,
        ),
        HomeRecommendedCourse(
          id: 'hc_003',
          title: 'Python 데이터 분석',
          instructor: '박데이터',
          description: 'Pandas, NumPy를 활용한 데이터 분석과 시각화를 실습과 함께 학습합니다.',
          price: '₩79,000',
          rating: 4.7,
          studentCount: 980,
        ),
      ],
      members: const [
        Member(
          id: 'mem_001',
          name: '관리자',
          email: 'admin@example.com',
          role: MemberRole.admin,
          isActive: true,
        ),
        Member(
          id: 'mem_002',
          name: '홍길동',
          email: 'user1@example.com',
          role: MemberRole.user,
          isActive: true,
        ),
        Member(
          id: 'mem_003',
          name: '김철수',
          email: 'user2@example.com',
          role: MemberRole.user,
          isActive: false,
        ),
      ],
    );
  }

  // ===== getters =====
  Place get place => _place;
  List<HomeNotice> get homeNotices => List.unmodifiable(_homeNotices);
  List<HomePromotion> get homePromotions => List.unmodifiable(_homePromotions);
  List<HomeRecommendedCourse> get homeRecommendedCourses =>
      List.unmodifiable(_homeRecommendedCourses);
  List<Member> get members => List.unmodifiable(_members);

  // ===== 홈 데이터 CRUD =====
  void addHomeNotice(HomeNotice notice) {
    _homeNotices.insert(0, notice);
    notifyListeners();
  }

  void updateHomeNotice(HomeNotice notice) {
    final idx = _homeNotices.indexWhere((n) => n.id == notice.id);
    if (idx < 0) return;
    _homeNotices[idx] = notice;
    notifyListeners();
  }

  void deleteHomeNotice(String id) {
    _homeNotices.removeWhere((n) => n.id == id);
    notifyListeners();
  }

  void addHomePromotion(HomePromotion promotion) {
    _homePromotions.insert(0, promotion);
    notifyListeners();
  }

  void updateHomePromotion(HomePromotion promotion) {
    final idx = _homePromotions.indexWhere((p) => p.id == promotion.id);
    if (idx < 0) return;
    _homePromotions[idx] = promotion;
    notifyListeners();
  }

  void deleteHomePromotion(String id) {
    _homePromotions.removeWhere((p) => p.id == id);
    notifyListeners();
  }

  void addHomeRecommendedCourse(HomeRecommendedCourse course) {
    _homeRecommendedCourses.insert(0, course);
    notifyListeners();
  }

  void updateHomeRecommendedCourse(HomeRecommendedCourse course) {
    final idx = _homeRecommendedCourses.indexWhere((c) => c.id == course.id);
    if (idx < 0) return;
    _homeRecommendedCourses[idx] = course;
    notifyListeners();
  }

  void deleteHomeRecommendedCourse(String id) {
    _homeRecommendedCourses.removeWhere((c) => c.id == id);
    notifyListeners();
  }

  // ===== 코스(예약) CRUD =====
  void addReservationCourse(reservation_models.Course course) {
    _place = _place.copyWith(courses: [course, ..._place.courses]);
    notifyListeners();
  }

  void updateReservationCourse(reservation_models.Course course) {
    final updated = _place.courses
        .map((c) => c.id == course.id ? course : c)
        .toList();
    _place = _place.copyWith(courses: updated);
    notifyListeners();
  }

  void deleteReservationCourse(String courseId) {
    _place = _place.copyWith(
      courses: _place.courses.where((c) => c.id != courseId).toList(),
    );
    notifyListeners();
  }

  // ===== 멤버 CRUD =====
  void addMember(Member member) {
    _members.insert(0, member);
    notifyListeners();
  }

  void updateMember(Member member) {
    final idx = _members.indexWhere((m) => m.id == member.id);
    if (idx < 0) return;
    _members[idx] = member;
    notifyListeners();
  }

  void deleteMember(String id) {
    _members.removeWhere((m) => m.id == id);
    notifyListeners();
  }
}
