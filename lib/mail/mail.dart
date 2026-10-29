import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'mail_account.dart';

class Mail {
  const Mail(
    this.from,
    this.subject,
    this.body,
    this.length,
    this.draft, {
    this.html,
    this.source = '예시 메일',
    this.date,
    this.account,
    this.uid,
    this.seen = false,
    this.address = '',
    this.messageId,
  });

  /// Message-ID header, so a reply threads under this mail.
  final String? messageId;
  final String from;

  /// Where a reply goes: the reply-to or sender address (the recipient's
  /// for sent mail); empty for the example mails.
  final String address;
  final String subject;
  final String body;

  /// How long reading it aloud takes, shown beside the waveform.
  final String length;
  final String draft;

  /// Original HTML body, shown as sent so its images and layout survive;
  /// [body] stays the plain text to read aloud.
  final String? html;

  /// Mail service it came from, e.g. 네이버 메일.
  final String source;
  final DateTime? date;

  /// Where to mark it read; null for the example mails.
  final MailAccount? account;
  final int? uid;

  /// Already read when fetched, or sent by the user.
  final bool seen;
}

/// Marks [mail] read on its server, then tells [onRead]. Best effort: a
/// failure just leaves it unread.
void markRead(Mail mail, void Function(Mail)? onRead) {
  if (mail case Mail(:final account?, :final uid?, seen: false)) {
    account
        .markSeen(uid)
        .then(
          (_) => onRead?.call(mail),
          onError: (Object e) {
            debugPrint('mark read failed: $e');
          },
        );
  }
}

const mockMails = [
  Mail(
    '프로젝트 운영팀',
    '오늘 일정 안내',
    '오늘 오후 3시 기획 회의가\n4층 회의실에서 열립니다.\n자료를 미리 확인해 주세요.',
    '0:18',
    '안녕하세요,\n메일 확인했습니다.\n오늘 오후 회의에\n참석하겠습니다.\n감사합니다.',
  ),
  Mail(
    '김서연 매니저',
    '견적서 회신 부탁드립니다',
    '지난주 요청하신 견적서를 첨부합니다.\n금요일까지 검토 후\n회신 부탁드립니다.',
    '0:14',
    '안녕하세요,\n견적서 잘 받았습니다.\n금요일까지 검토 후\n회신드리겠습니다.',
  ),
  Mail(
    '네이버페이',
    '결제 완료 안내',
    '주문하신 상품의 결제가\n정상적으로 완료되었습니다.',
    '0:09',
    '확인했습니다.\n감사합니다.',
  ),
];

/// Mail lists in the menu, each across every linked account.
enum MailFolder {
  all('전체 메일'),
  unread('안 읽은 메일'),
  sent('보낸 메일'),
  starred('즐겨찾기'),
  trash('휴지통');

  const MailFolder(this.label);
  final String label;
}
