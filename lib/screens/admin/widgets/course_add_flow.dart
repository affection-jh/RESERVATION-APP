import 'package:flutter/material.dart';
import '../../../models/course.dart' as reservation_models;
import 'course_basic_info_screen.dart';
import 'course_color_selection_screen.dart';
import 'course_schedule_screen.dart';
import 'course_policy_edit_screen.dart';
import '../../../models/session_draft.dart';

/// 코스 추가 플로우 (라우터 역할)
class CourseAddFlow extends StatefulWidget {
  final reservation_models.Course? existingCourse;
  final Function(reservation_models.Course) onComplete;

  const CourseAddFlow({
    super.key,
    this.existingCourse,
    required this.onComplete,
  });

  @override
  State<CourseAddFlow> createState() => _CourseAddFlowState();
}

class _CourseAddFlowState extends State<CourseAddFlow> {
  // 각 화면 데이터 유지 (뒤로 갔다 와도 유지)
  CourseBasicInfoData? _savedBasicInfo;
  CourseColorSelectionData? _savedColorSelection;
  Map<int, List<SessionDraft>>? _savedDaySessions;
  int? _savedDefaultCapacity;

  @override
  Widget build(BuildContext context) {
    return CourseBasicInfoScreen(
      existingCourse: widget.existingCourse,
      savedBasicInfo: _savedBasicInfo,
      onNext: (basicInfo) {
        // 기본 정보 저장 (뒤로 갔다 와도 유지)
        setState(() {
          _savedBasicInfo = basicInfo;
        });
        Navigator.of(context)
            .push(
              MaterialPageRoute(
                builder: (context) => CourseColorSelectionScreen(
                  basicInfo: basicInfo,
                  existingCourse: widget.existingCourse,
                  savedColorSelection: _savedColorSelection,
                  onNext: (colorSelectionData) {
                    // 색상/요일 선택 데이터 저장 (뒤로 갔다 와도 유지)
                    setState(() {
                      _savedColorSelection = colorSelectionData;
                    });
                    Navigator.of(context)
                        .push(
                          MaterialPageRoute(
                            builder: (context) => CourseScheduleScreen(
                              colorSelectionData: colorSelectionData,
                              existingCourse: widget.existingCourse,
                              savedDaySessions: _savedDaySessions,
                              savedDefaultCapacity: _savedDefaultCapacity,
                              onSessionsChanged:
                                  (daySessions, defaultCapacity) {
                                    // 세션 데이터 저장 (뒤로 갔다 와도 유지)
                                    setState(() {
                                      _savedDaySessions = daySessions;
                                      _savedDefaultCapacity = defaultCapacity;
                                    });
                                  },
                              onComplete: (course) {
                                // 정책 설정 화면으로 이동
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (context) =>
                                        CoursePolicyEditScreen(
                                          courseId: course.id,
                                          requireSave: true,
                                          courseToRegister: course,
                                        ),
                                  ),
                                );
                              },
                            ),
                          ),
                        )
                        .then((_) {
                          // 뒤로 갔다 와도 세션 데이터는 유지됨
                        });
                  },
                ),
              ),
            )
            .then((_) {
              // 뒤로 갔다 와도 기본 정보는 유지됨
            });
      },
    );
  }

  // 최종 코스 등록 처리는 CoursePolicyEditScreen에서 수행
}
