import 'package:flutter/material.dart';

import 'subscription_metadata.dart';
import 'private_text.dart';

class SubscriptionCard extends StatelessWidget {
  const SubscriptionCard({
    super.key,
    required this.subscription,
    required this.count,
    required this.updating,
    required this.onRefresh,
    required this.onDelete,
    required this.onOpen,
    this.privateMode = false,
    this.onPin,
  });
  final Map<String, dynamic> subscription;
  final int count;
  final bool updating;
  final VoidCallback onRefresh, onDelete;
  final void Function(String) onOpen;
  final bool privateMode;
  final VoidCallback? onPin;

  @override
  Widget build(BuildContext context) {
    final metadata = SubscriptionMetadata.fromJson(
      Map<String, dynamic>.from(subscription['metadata'] as Map? ?? {}),
    );
    final colors = Theme.of(context).colorScheme;
    final skipped = (subscription['unsupportedProtocols'] as List? ?? [])
        .cast<String>();
    final warnings = (subscription['conversionWarnings'] as List? ?? [])
        .cast<String>();
    final quota = metadata.quotaKnown
        ? metadata.total > 0
              ? formatBytes(metadata.total)
              : 'Без лимита'
        : 'Лимит не указан';
    final usage = metadata.trafficKnown
        ? '${formatBytes(metadata.used)} / $quota'
        : 'Трафик не указан';
    final updated = DateTime.tryParse(subscription['updated'] as String? ?? '')
        ?.toLocal();
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: Icon(
          subscription['pinned'] == true
              ? Icons.push_pin_rounded
              : Icons.rss_feed_rounded,
        ),
        title: PrivateText(
          subscription['name'] as String,
          hidden: privateMode,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '$count профилей · $usage${skipped.isNotEmpty ? '\nПропущено: ${skipped.length} · ${skipped.toSet().map((value) => value.toUpperCase()).join(', ')}' : ''}',
          ),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          if (metadata.fraction != null) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: metadata.fraction,
              borderRadius: BorderRadius.circular(8),
              minHeight: 7,
            ),
          ],
          const SizedBox(height: 12),
          for (final warning in warnings)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.info_outline_rounded),
              title: Text(warning),
            ),
          detail(
            'Действует до',
            metadata.expiryKnown ? formatExpiry(metadata.expire) : 'Нет данных',
          ),
          if (metadata.updateHours != null)
            detail('Интервал провайдера', '${metadata.updateHours} ч'),
          if (updated != null)
            detail(
              'Обновлено',
              '${updated.day.toString().padLeft(2, '0')}.${updated.month.toString().padLeft(2, '0')} · ${updated.hour.toString().padLeft(2, '0')}:${updated.minute.toString().padLeft(2, '0')}',
            ),
          if (metadata.hwidActive)
            const ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.phonelink_lock_rounded),
              title: Text('Привязка к устройству активна'),
            ),
          if (metadata.announce.isNotEmpty)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.symmetric(vertical: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colors.secondaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(metadata.announce),
            ),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              if (onPin != null)
                TextButton.icon(
                  onPressed: onPin,
                  icon: const Icon(Icons.push_pin_outlined),
                  label: Text(
                    subscription['pinned'] == true ? 'Открепить' : 'Закрепить',
                  ),
                ),
              TextButton.icon(
                onPressed: updating ? null : onRefresh,
                icon: updating
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_rounded),
                label: Text(updating ? 'Обновляется…' : 'Обновить'),
              ),
              if (metadata.supportUrl != null)
                TextButton.icon(
                  onPressed: () => onOpen(metadata.supportUrl!),
                  icon: const Icon(Icons.support_agent_rounded),
                  label: const Text('Поддержка'),
                ),
              if (metadata.webUrl != null)
                TextButton.icon(
                  onPressed: () => onOpen(metadata.webUrl!),
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: const Text('Личный кабинет'),
                ),
              TextButton.icon(
                onPressed: updating ? null : onDelete,
                icon: const Icon(Icons.delete_outline_rounded),
                label: const Text('Удалить'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget detail(String name, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Text(name)),
        const SizedBox(width: 12),
        Flexible(child: Text(value, textAlign: TextAlign.end)),
      ],
    ),
  );
}
