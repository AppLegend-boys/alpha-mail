import 'package:flutter/material.dart';

import '../widgets.dart';
import 'connect.dart';

/// One error code: what went wrong, the steps that fix it, and pages
/// those steps need.
typedef Problem = ({
  String title,
  String cause,
  List<String> steps,
  List<(String, Uri)> links,
});

/// Every error code. The messages themselves stay one line, ending in
/// their code, e.g. "(L-01)".
final Map<String, Problem> problems = {
  'C-01': (
    title: '인터넷 연결 안 됨',
    cause: '휴대폰이 인터넷에 연결되어 있지 않아 메일 서버에 닿지 못했어요.',
    steps: [
      '와이파이나 모바일 데이터가 켜져 있는지, 비행기 모드가 꺼져 있는지 확인해 주세요.',
      '홈 화면을 아래로 당기면 메일을 다시 불러와요.',
    ],
    links: [],
  ),
  'C-02': (
    title: '메일 서버 연결 실패',
    cause: '메일 서버가 잠시 응답하지 않았거나, 계정의 메일 접근 설정이 바뀌었어요.',
    steps: [
      '잠시 후 홈 화면을 아래로 당겨 다시 불러와 주세요.',
      '네이버라면 메일 환경설정에서 IMAP/SMTP 사용이 켜져 있는지 확인해 주세요.',
      '계속되면 메일 연동하기에서 계정을 [연결 해제]한 뒤 다시 연결해 주세요.',
    ],
    links: [('네이버 IMAP 설정 열기', naverMail)],
  ),
  'L-01': (
    title: '네이버 로그인 실패',
    cause:
        '네이버는 외부 앱에서 평소 비밀번호로 로그인할 수 없어요. '
        '애플리케이션 비밀번호와 IMAP/SMTP 사용 설정이 필요해요.',
    steps: [
      '네이버 보안설정에서 2단계 인증을 켜고, 애플리케이션 비밀번호 관리에서 '
          '"직접 입력" → 이름 "Alpha Mail"로 비밀번호를 만들어요.',
      '네이버 메일 IMAP 설정에서 "IMAP/SMTP 사용"을 "사용함"으로 저장해요.',
      '메일 연동하기 > 네이버에서 아이디와 방금 만든 비밀번호를 넣어요.',
    ],
    links: [('네이버 보안설정 열기', naverSecurity), ('네이버 IMAP 설정 열기', naverMail)],
  ),
  'L-02': (
    title: '구글 로그인 실패',
    cause: '구글 로그인이 끝나지 않았거나, 메일 접근 권한이 없거나 만료됐어요.',
    steps: [
      '메일 연동하기 > Gmail에서 다시 로그인해 주세요.',
      '로그인 창에서 메일 읽기·보내기 권한 체크를 모두 켜고 [계속]을 눌러요.',
      '그래도 안 되면 구글 계정 권한에서 Alpha Mail을 삭제한 뒤 다시 연결해 주세요.',
      '회사·학교 계정이면 관리자가 외부 앱의 메일 접근을 막아 두었을 수 있어요. 관리자에게 문의해 주세요.',
    ],
    links: [
      ('구글 계정 권한 열기', Uri.parse('https://myaccount.google.com/permissions')),
    ],
  ),
  'L-03': (
    title: '마이크로소프트 로그인 실패',
    cause: '마이크로소프트 로그인이 끝나지 않았거나, Outlook에서 IMAP 사용이 꺼져 있거나, 메일 접근 권한이 만료됐어요.',
    steps: [
      'outlook.com 설정 > 메일 > 전달 및 IMAP에서 '
          '"장치 및 앱에서 IMAP 사용"을 켜고 저장해요.',
      '메일 연동하기 > Outlook에서 다시 로그인하고 권한 요청에 [동의]를 눌러요.',
      '그래도 안 되면 마이크로소프트 계정의 앱 권한에서 Alpha Mail을 삭제한 뒤 다시 연결해 주세요.',
      '회사·학교 계정이면 관리자가 IMAP·SMTP 접근을 막아 두었을 수 있어요. 관리자에게 문의해 주세요.',
    ],
    links: [
      (
        'Outlook IMAP 설정 열기',
        Uri.parse('https://outlook.live.com/mail/0/options/mail/forwarding'),
      ),
      ('마이크로소프트 앱 권한 열기', Uri.parse('https://account.live.com/consent/Manage')),
    ],
  ),
  'V-01': (
    title: '한국어 오프라인 음성 없음',
    cause:
        '메일 내용이 밖으로 나가지 않도록 기기 안에 받아 둔 음성만 써요. '
        '이 휴대폰에는 한국어 음성이 아직 없어요.',
    steps: [
      '안드로이드: 설정에서 "텍스트 음성 변환"을 검색해 열고, '
          '기본 엔진의 설정 → 음성 데이터 설치 → 한국어를 내려받아요.',
      '아이폰: 설정 > 손쉬운 사용 > 읽기 및 말하기 > 음성 > 한국어에서 목소리를 내려받아요.',
      '다 받으면 앱을 껐다 켜 주세요.',
    ],
    links: [],
  ),
};

final _code = RegExp(r' ?\(([A-Z]-\d\d)\)');

/// The code in [message], if it's one of [problems].
String? problemCode(String message) => switch (_code.firstMatch(message)) {
  final m? when problems.containsKey(m[1]) => m[1],
  _ => null,
};

/// [message] without its code, for reading aloud.
String withoutCode(String message) => message.replaceAll(_code, '');

/// Shows [message], with 자세히 to open what its code means.
void showProblem(BuildContext context, String message) {
  final code = problemCode(message);
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      action: code == null
          ? null
          : SnackBarAction(
              label: '자세히',
              onPressed: () => explainProblem(context, code),
            ),
    ),
  );
}

void explainProblem(BuildContext context, String code) {
  final problem = problems[code]!;
  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('${problem.title} ($code)'),
      content: SingleChildScrollView(child: _Fix(problem)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('확인'),
        ),
      ],
    ),
  );
}

/// A problem's cause, numbered steps, and buttons opening its pages.
class _Fix extends StatelessWidget {
  const _Fix(this.problem);

  final Problem problem;

  @override
  Widget build(BuildContext context) {
    final hint = TextStyle(
      fontSize: 14,
      height: 1.5,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    const bold = TextStyle(fontSize: 15, fontWeight: FontWeight.w700);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(problem.cause, style: hint),
        const SizedBox(height: 12),
        const Text('이렇게 해 보세요', style: bold),
        const SizedBox(height: 6),
        for (final (i, step) in problem.steps.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('${i + 1}. $step', style: hint),
          ),
        for (final (label, url) in problem.links)
          TextButton.icon(
            style: TextButton.styleFrom(padding: EdgeInsets.zero),
            onPressed: () => openLink(context, url),
            icon: const Icon(Icons.open_in_new_rounded, size: 18),
            label: Text(label),
          ),
      ],
    );
  }
}

/// An error shown in place, with 자세히 when it has a code.
class ProblemText extends StatelessWidget {
  const ProblemText(this.message, {super.key, this.style});

  final String message;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final code = problemCode(message);
    return Semantics(
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message, style: style),
          if (code != null)
            TextButton(
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
              onPressed: () => explainProblem(context, code),
              child: const Text('자세히'),
            ),
        ],
      ),
    );
  }
}

/// 도움말: a table of every error code; tapping one opens its fix and
/// closes whichever was open.
class HelpScreen extends StatefulWidget {
  const HelpScreen({super.key, required this.from});

  final List<String> from;

  @override
  State<HelpScreen> createState() => _HelpScreenState();
}

class _HelpScreenState extends State<HelpScreen> {
  String? _open;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AppPage(
      trail: [...widget.from, '도움말'],
      children: [
        const ScreenTitle('도움말', '오류 코드별 해결 방법'),
        const SizedBox(height: 16),
        VoiceCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (final (i, MapEntry(key: code, value: problem))
                  in problems.entries.indexed) ...[
                if (i > 0) Divider(height: 1, color: colors.outlineVariant),
                Semantics(
                  expanded: _open == code,
                  child: InkWell(
                    onTap: () =>
                        setState(() => _open = _open == code ? null : code),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 56,
                            child: Text(
                              code,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              problem.title,
                              style: const TextStyle(fontSize: 16),
                            ),
                          ),
                          AnimatedRotation(
                            turns: _open == code ? 0.5 : 0,
                            duration: const Duration(milliseconds: 200),
                            child: Icon(
                              Icons.expand_more_rounded,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 200),
                  alignment: Alignment.topCenter,
                  child: _open == code
                      ? Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                          child: _Fix(problem),
                        )
                      : const SizedBox(width: double.infinity),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
