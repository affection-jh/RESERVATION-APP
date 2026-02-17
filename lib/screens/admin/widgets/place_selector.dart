import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../theme/app_colors.dart';
import '../../../widgets/cached_image_widget.dart';
import '../../../models/place.dart';
import '../../../providers/place_provider.dart';
import '../../../providers/auth_provider.dart';
import '../../../services/reservation_service.dart';
import '../../../services/auth_service.dart';
import '../../../utils/snackbar_util.dart';

/// 플레이스 선택기 (현재 플레이스 표시, 다중 시 전환 드롭다운)
class PlaceSelector extends StatefulWidget {
  final VoidCallback? onEditTap;
  final Future<List<Place>> Function()? loadPlaces;
  final Widget? trailing;
  final VoidCallback? onTrailingTap;
  final bool showDescription;

  const PlaceSelector({
    super.key,
    this.onEditTap,
    this.loadPlaces,
    this.trailing,
    this.onTrailingTap,
    this.showDescription = false,
  });

  @override
  State<PlaceSelector> createState() => _PlaceSelectorState();
}

class _PlaceSelectorState extends State<PlaceSelector> {
  bool _isPlaceListExpanded = false;

  List<Place> _getPlaces() {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final placeProvider = Provider.of<PlaceProvider>(context, listen: false);

    final placeIds = authProvider.adminManagedPlaceIds;
    if (placeIds.isEmpty) return [];

    return placeIds
        .map((placeId) => placeProvider.getPlace(placeId))
        .whereType<Place>()
        .toList();
  }

  Future<void> _switchPlace(BuildContext context, Place newPlace) async {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);

    if (!authProvider.adminManagedPlaceIds.contains(newPlace.id)) return;

    try {
      final placeProvider = Provider.of<PlaceProvider>(context, listen: false);
      placeProvider.setCurrentPlace(newPlace);

      final reservationService = ReservationService();
      reservationService.setPlace(newPlace);

      final authService = AuthService();
      await authService.updateLastAccessedPlace(newPlace.id);

      if (mounted) {
        setState(() => _isPlaceListExpanded = false);
      }
    } catch (e) {
      if (mounted) {
        SnackbarUtil.showInfo(context, '플레이스 전환 중 오류가 발생했습니다: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (context) {
        final placeProvider = Provider.of<PlaceProvider>(context);
        final authProvider = Provider.of<AuthProvider>(context);
        final currentPlace = placeProvider.currentPlace;
        final managedPlaceIds = authProvider.adminManagedPlaceIds;

        if (currentPlace == null) return const SizedBox.shrink();

        final placeName = currentPlace.name;
        final descriptionText = (currentPlace.description ?? '').trim();
        final showDescriptionLine =
            widget.showDescription && descriptionText.isNotEmpty;
        final hasMultiplePlaces = managedPlaceIds.length > 1;
        final currentPlaceId = currentPlace.id;
        final places = _getPlaces();

        return Padding(
          padding: const EdgeInsets.only(left: 20, right: 10, top: 10),
          child: Column(
            children: [
              InkWell(
                onTap:
                    hasMultiplePlaces
                        ? () {
                          setState(() {
                            _isPlaceListExpanded = !_isPlaceListExpanded;
                          });
                        }
                        : null,
                borderRadius: BorderRadius.circular(16),
                child: Row(
                  children: [
                    PlaceImageWidget(
                      imageUrl: currentPlace.imageUrl,
                      width: 46,
                      height: 46,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            placeName,
                            style: TextStyle(
                              fontSize: showDescriptionLine ? 18 : 20,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary,
                              letterSpacing: -0.5,
                            ),
                          ),
                          if (showDescriptionLine)
                            Text(
                              descriptionText,
                              style: TextStyle(
                                fontSize: 14,
                                color: AppColors.textSecondary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                    if (hasMultiplePlaces)
                      Icon(
                        _isPlaceListExpanded
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        color: AppColors.textSecondary,
                        size: 24,
                      ),
                    if (widget.trailing != null) ...[
                      const SizedBox(width: 16),
                      widget.onTrailingTap != null
                          ? IconButton(
                            color: AppColors.textSecondary,
                            iconSize: 24,
                            onPressed: widget.onTrailingTap,
                            icon: widget.trailing!,
                          )
                          : widget.trailing!,
                    ],
                  ],
                ),
              ),
              if (_isPlaceListExpanded && hasMultiplePlaces) ...[
                const SizedBox(height: 12),
                Column(
                  children:
                      places.map((place) {
                        final isCurrentPlace = place.id == currentPlaceId;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: InkWell(
                            onTap:
                                isCurrentPlace
                                    ? null
                                    : () => _switchPlace(context, place),
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                              decoration: BoxDecoration(
                                color:
                                    isCurrentPlace
                                        ? AppColors.primaryGreen.withOpacity(
                                          0.1,
                                        )
                                        : AppColors.backgroundWhite,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color:
                                      isCurrentPlace
                                          ? AppColors.primaryGreen
                                          : AppColors.textSecondary.withOpacity(
                                            0.2,
                                          ),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      place.name,
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w500,
                                        color:
                                            isCurrentPlace
                                                ? AppColors.primaryGreen
                                                : AppColors.textPrimary,
                                      ),
                                    ),
                                  ),
                                  if (isCurrentPlace)
                                    Icon(
                                      Icons.check_circle,
                                      color: AppColors.primaryGreen,
                                      size: 20,
                                    ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
