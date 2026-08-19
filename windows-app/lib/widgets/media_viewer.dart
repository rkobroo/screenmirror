import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// In-app viewer for chat photos and videos. Avoids launching an external
/// app: photos are shown with pinch-zoom, videos play inline with controls.
class MediaViewerScreen extends StatefulWidget {
  const MediaViewerScreen({super.key, required this.filePath, required this.isVideo});

  final String filePath;
  final bool isVideo;

  @override
  State<MediaViewerScreen> createState() => _MediaViewerScreenState();
}

class _MediaViewerScreenState extends State<MediaViewerScreen> {
  VideoPlayerController? _controller;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    if (widget.isVideo) {
      if (widget.filePath.isEmpty) {
        _error = true;
        setState(() {});
        return;
      }
      _controller = VideoPlayerController.file(File(widget.filePath))
        ..initialize().then((_) {
          if (mounted) {
            setState(() {});
            _controller?.play();
          }
        }).catchError((e) {
          debugPrint('MediaViewer video init error: $e');
          if (mounted) {
            _error = true;
            setState(() {});
          }
        });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final initialized = _controller?.value.isInitialized == true;
    final fallback = Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          widget.isVideo ? 'Unable to play this video' : 'Image not available',
          style: const TextStyle(color: Colors.white70),
          textAlign: TextAlign.center,
        ),
      ),
    );
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Center(
        child: widget.isVideo
            ? (_error
                ? fallback
                : (initialized
                    ? AspectRatio(
                        aspectRatio: _controller!.value.aspectRatio,
                        child: VideoPlayer(_controller!),
                      )
                    : const CircularProgressIndicator()))
            : (widget.filePath.isEmpty
                ? fallback
                : InteractiveViewer(
                    child: Image.file(File(widget.filePath),
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => fallback),
                  )),
      ),
      floatingActionButton: widget.isVideo && initialized && !_error
          ? FloatingActionButton(
              onPressed: () {
                setState(() {
                  _controller!.value.isPlaying
                      ? _controller!.pause()
                      : _controller!.play();
                });
              },
              child: Icon(
                _controller!.value.isPlaying ? Icons.pause : Icons.play_arrow,
              ),
            )
          : null,
    );
  }
}
