import 'dart:ui';

import 'package:flutter/material.dart';

/// В скрытом режиме исходный текст вообще не рисуется и не попадает в semantics.
class PrivateText extends StatelessWidget {
  const PrivateText(
    this.text, {
    super.key,
    required this.hidden,
    this.style,
    this.maxLines,
    this.overflow,
    this.textAlign,
  });
  final String text;
  final bool hidden;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;
  @override
  Widget build(BuildContext context) => hidden
      ? Semantics(
          label: 'Личные данные скрыты',
          child: ExcludeSemantics(
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
              child: Text(
                '████ ████ ██████',
                style: (style ?? DefaultTextStyle.of(context).style).copyWith(
                  color: Theme.of(context).colorScheme.primary
                      .withValues(alpha: 0.24),
                ),
                maxLines: 1,
                overflow: TextOverflow.clip,
              ),
            ),
          ),
        )
      : Text(
          text,
          style: style,
          maxLines: maxLines,
          overflow: overflow,
          textAlign: textAlign,
        );
}
