import 'dart:async';

import 'package:flutter/material.dart';

enum DemoScenario { normal, overflow, profileDemo }

DemoScenario parseScenario(String raw) {
  switch (raw) {
    case 'overflow':
      return DemoScenario.overflow;
    case 'profile_demo':
      return DemoScenario.profileDemo;
    default:
      return DemoScenario.normal;
  }
}

class CounterModel {
  CounterModel({this.value = 0});

  int value;

  void increment() {
    value += 1;
  }
}

class SampleApp extends StatefulWidget {
  SampleApp({
    super.key,
    required this.scenario,
    CounterModel? counter,
  }) : counter = counter ?? CounterModel();

  final DemoScenario scenario;
  final CounterModel counter;

  @override
  State<SampleApp> createState() => _SampleAppState();
}

class _SampleAppState extends State<SampleApp> {
  late final CounterModel _counter = widget.counter;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FlutterHelm Sample',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      ),
      home: widget.scenario == DemoScenario.overflow
          ? const OverflowPage()
          : widget.scenario == DemoScenario.profileDemo
          ? const ProfileDemoPage()
          : CounterPage(counter: _counter),
    );
  }
}

class CounterPage extends StatefulWidget {
  const CounterPage({super.key, required this.counter});

  final CounterModel counter;

  @override
  State<CounterPage> createState() => _CounterPageState();
}

class _CounterPageState extends State<CounterPage> {
  void _increment() {
    setState(widget.counter.increment);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('FlutterHelm Sample')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Text('Counter value'),
            Text(
              '${widget.counter.value}',
              style: Theme.of(context).textTheme.displaySmall,
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _increment,
        child: const Icon(Icons.add),
      ),
    );
  }
}

class OverflowPage extends StatefulWidget {
  const OverflowPage({super.key});

  @override
  State<OverflowPage> createState() => _OverflowPageState();
}

class _OverflowPageState extends State<OverflowPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Emit a stable sentinel so the harness can assert overflow diagnostics.
      // ignore: avoid_print
      print('A RenderFlex overflowed by 108 pixels on the right.');
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Overflow Scenario')),
      body: Center(
        child: SizedBox(
          width: 180,
          child: Row(
            children: const <Widget>[
              _OverflowBlock(color: Colors.orange, label: 'A'),
              _OverflowBlock(color: Colors.indigo, label: 'B'),
            ],
          ),
        ),
      ),
    );
  }
}

class _OverflowBlock extends StatelessWidget {
  const _OverflowBlock({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 140,
      height: 64,
      margin: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.center,
      color: color,
      child: Text(
        'Overflow $label',
        style: const TextStyle(color: Colors.white),
      ),
    );
  }
}

class ProfileDemoPage extends StatefulWidget {
  const ProfileDemoPage({super.key});

  @override
  State<ProfileDemoPage> createState() => _ProfileDemoPageState();
}

class _ProfileDemoPageState extends State<ProfileDemoPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..repeat();
  final List<List<int>> _allocations = <List<int>>[];
  Timer? _allocationTimer;
  int _tick = 0;

  @override
  void initState() {
    super.initState();
    _allocationTimer = Timer.periodic(const Duration(milliseconds: 120), (_) {
      final allocation = List<int>.generate(4096, (index) => index + _tick);
      if (_allocations.length >= 8) {
        _allocations.removeAt(0);
      }
      _allocations.add(allocation);
      if (!mounted) {
        return;
      }
      setState(() {
        _tick += 1;
      });
    });
  }

  @override
  void dispose() {
    _allocationTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile Demo')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            AnimatedBuilder(
              animation: _controller,
              builder: (BuildContext context, Widget? child) {
                return Transform.rotate(
                  angle: _controller.value * 6.28318,
                  child: child,
                );
              },
              child: Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  color: Colors.teal,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: const <BoxShadow>[
                    BoxShadow(
                      blurRadius: 24,
                      offset: Offset(0, 10),
                      color: Color(0x33000000),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Frames: $_tick',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Active allocations: ${_allocations.length}',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ],
        ),
      ),
    );
  }
}
