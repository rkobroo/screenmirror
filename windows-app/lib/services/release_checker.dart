import 'dart:convert';
import 'dart:io';

/// Information about the latest GitHub release, fetched anonymously.
class ReleaseInfo {
  const ReleaseInfo({
    required this.tagName,
    required this.name,
    required this.publishedAt,
    required this.body,
    required this.androidAsset,
    required this.windowsAsset,
  });

  final String tagName;
  final String name;
  final DateTime? publishedAt;
  final String body;
  final String? androidAsset;
  final String? windowsAsset;

  bool get isPreRelease => tagName.contains('-');
}

/// Fetches release metadata from the GitHub Releases API so the desktop app
/// can show an "update available" prompt and link to download assets.
class ReleaseChecker {
  ReleaseChecker({this.repo = 'rkobroo/screenmirror'});

  final String repo;

  Future<ReleaseInfo?> latest() async {
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 8);
      try {
        final request = await client.getUrl(
          Uri.parse('https://api.github.com/repos/$repo/releases/latest'),
        );
        request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
        request.headers.set(HttpHeaders.userAgentHeader, 'MirrorLink');
        final response = await request.close();
        if (response.statusCode != 200) return null;
        final body = await response.transform(utf8.decoder).join();
        return _parse(body);
      } finally {
        client.close();
      }
    } catch (_) {
      return null;
    }
  }

  ReleaseInfo? _parse(String body) {
    final json = jsonDecode(body) as Map<String, dynamic>;
    String? asset(String suffix) {
      final assets = json['assets'] as List?;
      if (assets == null) return null;
      for (final a in assets) {
        final name = (a as Map)['name'] as String? ?? '';
        if (name.endsWith(suffix)) return a['browser_download_url'] as String?;
      }
      return null;
    }

    return ReleaseInfo(
      tagName: json['tag_name'] as String? ?? '',
      name: json['name'] as String? ?? json['tag_name'] as String? ?? '',
      publishedAt: DateTime.tryParse(json['published_at'] as String? ?? ''),
      body: json['body'] as String? ?? '',
      androidAsset: asset('.apk'),
      windowsAsset: asset('.exe'),
    );
  }
}
