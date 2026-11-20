import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'common.dart';

class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.title,
    this.subtitle,
    this.subtitleWidget,
    required this.rows,
  });

  final String title;
  final String? subtitle;
  final Widget? subtitleWidget;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text(title, style: context.sectionTitle),
        ),
        if (subtitle != null || subtitleWidget != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 6, 6, 0),
            child: subtitleWidget ?? Text(subtitle!, style: context.body),
          ),
        const SizedBox(height: 16),
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadii.card),
          child: ColoredBox(
            color: AppColors.card,
            child: Column(
              children: [
                for (var i = 0; i < rows.length; i++) ...[
                  if (i > 0)
                    const Divider(
                      height: 2,
                      thickness: 2,
                      color: AppColors.divider,
                    ),
                  rows[i],
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    this.label,
    this.sublabel,
    this.sublabelColor,
    this.leading,
    this.trailing,
    this.trailingFlex = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
  });

  final String? label;
  final String? sublabel;
  final Color? sublabelColor;
  final Widget? leading;
  final Widget? trailing;

  final bool trailingFlex;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label != null) Text(label!, style: context.label),
        if (sublabel != null) ...[
          const SizedBox(height: 2),
          Text(
            sublabel!,
            style: sublabelColor == null
                ? context.caption
                : context.caption.copyWith(
                    color: sublabelColor,
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
          ),
        ],
      ],
    );

    return Padding(
      padding: padding,
      child: Row(
        children: [
          ?leading,
          Expanded(child: text),
          if (trailing != null) ...[
            const SizedBox(width: 16),
            trailingFlex
                ? Expanded(child: trailing!)
                : Flexible(child: trailing!),
          ],
        ],
      ),
    );
  }
}

class StatusText extends StatelessWidget {
  const StatusText(this.text, {super.key, this.positive = false});

  final String text;
  final bool positive;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: context.label.copyWith(
        fontSize: 15,
        fontWeight: positive ? FontWeight.w800 : FontWeight.w500,
        color: positive ? AppColors.online : AppColors.text,
      ),
    );
  }
}

const _pillPadding = EdgeInsets.symmetric(horizontal: 20, vertical: 14);

class PillTextField extends StatefulWidget {
  const PillTextField({
    super.key,
    required this.initialValue,
    required this.onChanged,
    this.hint,
    this.obscure = false,
  });

  final String initialValue;
  final ValueChanged<String> onChanged;
  final String? hint;
  final bool obscure;

  @override
  State<PillTextField> createState() => _PillTextFieldState();
}

class _PillTextFieldState extends State<PillTextField> {
  late final _controller = TextEditingController(text: widget.initialValue);

  @override
  void didUpdateWidget(PillTextField old) {
    super.didUpdateWidget(old);
    if (widget.initialValue != old.initialValue &&
        _controller.text == old.initialValue) {
      _controller.text = widget.initialValue;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      onChanged: widget.onChanged,
      obscureText: widget.obscure,
      obscuringCharacter: '•',
      style: context.label.copyWith(fontWeight: FontWeight.w500),
      decoration: InputDecoration(
        isDense: true,
        hintText: widget.hint,
        hintStyle: context.label.copyWith(
          fontWeight: FontWeight.w500,
          color: AppColors.textFaint,
        ),
        filled: true,
        fillColor: AppColors.raised,
        contentPadding: _pillPadding,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(40),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(40),
          borderSide: const BorderSide(
            color: AppColors.accent,
            width: AppMotion.ringWidth,
          ),
        ),
      ),
    );
  }
}

class PillDropdown<T> extends StatelessWidget {
  const PillDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.labelOf,
    required this.onChanged,
    this.hint,
  });

  final T? value;
  final List<T> items;
  final String? hint;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(left: 20, right: 12),
      decoration: BoxDecoration(
        color: AppColors.raised,
        borderRadius: BorderRadius.circular(40),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: items.contains(value) ? value : null,
          hint: hint == null
              ? null
              : Text(
                  hint!,
                  style: context.label.copyWith(
                    fontWeight: FontWeight.w500,
                    color: AppColors.textFaint,
                  ),
                ),
          isExpanded: true,
          dropdownColor: AppColors.raised,
          borderRadius: BorderRadius.circular(AppRadii.tile),
          icon: const Icon(
            Icons.keyboard_arrow_down_rounded,
            color: AppColors.text,
          ),
          style: context.label.copyWith(fontWeight: FontWeight.w500),
          items: [
            for (final item in items)
              DropdownMenuItem(
                value: item,
                child: Text(labelOf(item), overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (v) => v == null ? null : onChanged(v),
        ),
      ),
    );
  }
}

class PillSegmented<T> extends StatelessWidget {
  const PillSegmented({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.raised,
        borderRadius: BorderRadius.circular(40),
      ),
      child: Row(
        children: [
          for (final MapEntry(key: option, value: label) in options.entries)
            Expanded(
              child: Semantics(
                button: true,
                selected: option == value,
                label: label,
                excludeSemantics: true,
                child: GestureDetector(
                  onTap: () => onChanged(option),
                  child: AnimatedContainer(
                    duration: AppMotion.of(context, AppMotion.fast),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: option == value
                          ? AppColors.text
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(40),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      label,
                      style: context.label.copyWith(
                        fontSize: 15,
                        color: option == value
                            ? AppColors.background
                            : AppColors.text,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class ValueChip extends StatelessWidget {
  const ValueChip({
    super.key,
    required this.label,
    required this.onTap,
    this.tooltip,
  });

  final String label;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip ?? '',
      child: FocusGlow(
        borderRadius: BorderRadius.circular(40),
        child: Material(
          color: AppColors.raised,
          shape: const StadiumBorder(),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Text(
                label,
                style: context.label.copyWith(fontWeight: FontWeight.w500),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
