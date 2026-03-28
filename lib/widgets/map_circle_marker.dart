import 'package:flutter/material.dart';
import 'package:ontacoche/theme/app_colors.dart';

class MapCircleMarker extends StatelessWidget {
  const MapCircleMarker({super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 24,
      height: 24,
      child: Center(
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            Container(
              width: 24,
              height: 24,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.surfaceContainerLowest,
              ),
            ),
            Container(
              width: 12,
              height: 12,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.blue,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
