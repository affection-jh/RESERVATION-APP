import 'dart:async';
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// 크롬 스타일 공룡 게임 위젯
class DinoGameWidget extends StatefulWidget {
  const DinoGameWidget({super.key});

  @override
  State<DinoGameWidget> createState() => _DinoGameWidgetState();
}

class _DinoGameWidgetState extends State<DinoGameWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  double _dinoY = 0.0; // 공룡의 Y 위치 (0 = 땅, 높을수록 위)
  double _dinoVelocity = 0.0; // 공룡의 속도
  double _obstacleX = 1.0; // 장애물의 X 위치 (1.0 = 오른쪽 끝, 0.0 = 왼쪽 끝)
  bool _isGameOver = false;
  int _score = 0;
  bool _isJumping = false;
  Timer? _gameTimer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 16), // ~60fps
    )..addListener(_updateGame);
    _startGame();
  }

  @override
  void dispose() {
    _gameTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _startGame() {
    _controller.repeat();
    _gameTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      if (!_isGameOver) {
        setState(() {
          _score++;
        });
      }
    });
  }

  void _updateGame() {
    if (_isGameOver) return;

    setState(() {
      // 공룡 점프 물리
      if (_isJumping || _dinoY > 0) {
        _dinoVelocity -= 0.5; // 중력
        _dinoY += _dinoVelocity;
        if (_dinoY <= 0) {
          _dinoY = 0;
          _dinoVelocity = 0;
          _isJumping = false;
        }
      }

      // 장애물 이동
      _obstacleX -= 0.02;
      if (_obstacleX < -0.1) {
        _obstacleX = 1.0;
      }

      // 충돌 감지
      if (_obstacleX < 0.15 && _obstacleX > 0.05 && _dinoY < 0.15) {
        _isGameOver = true;
        _controller.stop();
        _gameTimer?.cancel();
      }
    });
  }

  void _jump() {
    if (_dinoY == 0 && !_isGameOver) {
      setState(() {
        _isJumping = true;
        _dinoVelocity = 12.0;
      });
    }
  }

  void _restart() {
    setState(() {
      _dinoY = 0.0;
      _dinoVelocity = 0.0;
      _obstacleX = 1.0;
      _isGameOver = false;
      _score = 0;
      _isJumping = false;
    });
    _startGame();
    _controller.repeat();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _isGameOver ? _restart : _jump,
      child: Container(
        width: double.infinity,
        height: 200,
        decoration: BoxDecoration(
          color: AppColors.backgroundWhite,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.borderLight, width: 1),
        ),
        child: Stack(
          children: [
            // 땅
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              height: 20,
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.backgroundLight,
                  borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(16),
                    bottomRight: Radius.circular(16),
                  ),
                ),
              ),
            ),
            // 공룡
            Positioned(
              left: 40,
              bottom: 20 + (_dinoY * 2),
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: AppColors.primaryGreen,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Icon(Icons.pets, color: Colors.white, size: 20),
              ),
            ),
            // 장애물
            Positioned(
              left: MediaQuery.of(context).size.width * _obstacleX - 20,
              bottom: 20,
              child: Container(
                width: 20,
                height: 30,
                decoration: BoxDecoration(
                  color: AppColors.textSecondary,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            // 점수
            Positioned(
              top: 12,
              right: 16,
              child: Text(
                '$_score',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            // 게임 오버 오버레이
            if (_isGameOver)
              Positioned.fill(
                child: Container(
                  color: Colors.black.withOpacity(0.3),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '게임 오버!',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '탭하여 다시 시작',
                          style: TextStyle(
                            fontSize: 14,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
