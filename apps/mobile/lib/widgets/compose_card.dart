import 'package:flutter/material.dart';
import 'package:prism_ui/ui.dart';

import '../screens/ai_tab.dart';

/// Shared hero compose card — extracted from the Home screen's
/// private `_ComposeCard` (slice-7) so that both the Home tab and
/// the AI/Create tab can render the same surface.
///
/// Tapping the card pushes [AiTabScreen.routeName] so the user lands
/// on the full Create tab. From the Create tab itself the card does
/// nothing on tap (navigation would be a no-op loop), but the visual
/// surface is still valuable as a hero entry point to the
/// [NewVibeSheet].
class ComposeCard extends StatelessWidget {
  const ComposeCard({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () {
          Navigator.of(context).pushNamed(AiTabScreen.routeName);
        },
        child: Glass(
          intensity: GlassIntensity.heavy,
          radius: 20,
          padding: EdgeInsets.all(tokens.s4),
          child: Stack(
            children: [
              // Lilac glow blob in the top-right corner.
              Positioned(
                right: -30,
                top: -30,
                child: IgnorePointer(
                  child: Container(
                    width: 160,
                    height: 160,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: <Color>[
                          const Color(0xFFC8B4FF).withValues(alpha: 0.7),
                          const Color(0x00C8B4FF),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: <Color>[
                              Color(0xFF9BB8FF),
                              Color(0xFFD0A8FF),
                            ],
                          ),
                          boxShadow: <BoxShadow>[
                            BoxShadow(
                              color: Color(0x809BB8FF),
                              blurRadius: 8,
                              offset: Offset(0, 2),
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.auto_awesome,
                          size: 14,
                          color: Colors.white,
                        ),
                      ),
                      SizedBox(width: tokens.s2),
                      Text(
                        'ONE-TAP PLAYLIST',
                        style: scale.caption13.copyWith(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.5,
                          color: const Color(0xFF6E4AB8),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: tokens.s2),
                  Text(
                    "Describe a mood.\nWe'll compose the rest.",
                    style: scale.display28.copyWith(
                      fontSize: 22,
                      fontWeight: FontWeight.w500,
                      letterSpacing: -0.4,
                      height: 1.15,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  SizedBox(height: tokens.s1),
                  Text(
                    '"Rainy Sunday, slow coffee, jazz" →',
                    style: scale.body16.copyWith(
                      fontSize: 13,
                      color:
                          theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
