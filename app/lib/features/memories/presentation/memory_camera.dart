import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

class MemoryCapture {
  const MemoryCapture(this.file, this.capturedAt);
  final XFile file;
  final DateTime capturedAt;
}

class MemoryCamera extends StatefulWidget {
  const MemoryCamera({super.key});
  @override
  State<MemoryCamera> createState() => _MemoryCameraState();
}

class _MemoryCameraState extends State<MemoryCamera>
    with WidgetsBindingObserver {
  CameraController? controller;
  List<CameraDescription> cameras = [];
  int index = 0;
  int generation = 0;
  bool taking = false;
  String? error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    initialize();
  }

  Future<void> initialize() async {
    final token = ++generation;
    final previous = controller;
    controller = null;
    if (mounted) setState(() => error = null);
    await previous?.dispose();
    try {
      cameras = await availableCameras();
      if (!mounted || token != generation) return;
      if (cameras.isEmpty) {
        throw const FormatException('No camera is available on this device.');
      }
      final next = CameraController(
        cameras[index % cameras.length],
        ResolutionPreset.high,
        enableAudio: false,
      );
      controller = next;
      await next.initialize();
      if (!mounted || token != generation) return;
      setState(() {});
    } catch (e) {
      if (!mounted || token != generation) return;
      setState(
        () => error = e is CameraException && e.code.contains('Access')
            ? 'Allow camera access in your phone settings, then tap Try again.'
            : 'Could not open the camera. Close other camera apps and try again.',
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      initialize();
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      generation++;
      final previous = controller;
      controller = null;
      previous?.dispose();
    }
  }

  Future<void> capture() async {
    final camera = controller;
    if (taking || camera == null || !camera.value.isInitialized) return;
    setState(() => taking = true);
    try {
      final at = DateTime.now();
      final file = await camera.takePicture();
      if (mounted) Navigator.pop(context, MemoryCapture(file, at));
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Could not take the photo. Tap Try again.');
      }
    } finally {
      if (mounted) setState(() => taking = false);
    }
  }

  @override
  void dispose() {
    generation++;
    WidgetsBinding.instance.removeObserver(this);
    controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      title: const Text('People I met'),
    ),
    body: SafeArea(
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: error != null
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            error!,
                            style: const TextStyle(color: Colors.white),
                            textAlign: TextAlign.center,
                          ),
                          TextButton(
                            onPressed: initialize,
                            child: const Text(
                              'Try again',
                              style: TextStyle(color: Colors.white),
                            ),
                          ),
                        ],
                      ),
                    )
                  : controller?.value.isInitialized == true
                  ? CameraPreview(controller!)
                  : const CircularProgressIndicator(color: Colors.white),
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'A face to remember. Private when saved.',
              style: TextStyle(color: Colors.white70),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                const SizedBox(width: 48),
                Semantics(
                  label: 'Take photo',
                  button: true,
                  child: IconButton.filled(
                    tooltip: 'Take photo',
                    onPressed: taking || controller?.value.isInitialized != true
                        ? null
                        : capture,
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.black,
                      fixedSize: const Size(76, 76),
                    ),
                    icon: taking
                        ? const CircularProgressIndicator()
                        : const Icon(Icons.circle_outlined, size: 52),
                  ),
                ),
                IconButton(
                  tooltip: 'Switch camera',
                  onPressed: cameras.length < 2 || taking
                      ? null
                      : () {
                          index++;
                          initialize();
                        },
                  icon: const Icon(
                    Icons.flip_camera_android_outlined,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
