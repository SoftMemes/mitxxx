/// A single disclosure item shown on the onboarding and About screens.
class DisclosureItem {
  const DisclosureItem({required this.title, required this.body});
  final String title;
  final String body;
}

/// The four canonical disclosure points for MITxxx.
const List<DisclosureItem> kDisclosureItems = [
  DisclosureItem(
    title: 'Not affiliated with MIT',
    body:
        'MITxxx is an independent app and is not affiliated with, endorsed by, '
        'or officially connected to MIT or MIT OpenLearning.',
  ),
  DisclosureItem(
    title: 'Offline access to your enrolled courses',
    body:
        'This app lets you read and watch content from MIT Learn courses you are '
        'already enrolled in, including downloading video content for offline use.',
  ),
  DisclosureItem(
    title: 'Manage your courses on MIT Learn',
    body:
        'Enrolment, assignments, submissions, grading, and all other course '
        'management must be done directly on the MIT Learn platform '
        '(mitxonline.mit.edu).',
  ),
  DisclosureItem(
    title: 'Your data stays with MIT',
    body:
        "Your login credentials and course data are only shared with MIT's "
        'servers. They are never sent to any third-party services or stored '
        "outside of MIT's infrastructure and your own device.",
  ),
];
