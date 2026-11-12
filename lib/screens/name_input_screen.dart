import 'dart:math';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../app_session.dart';
import 'map_screen.dart';

class NameInputScreen extends StatefulWidget {
  final String groupId;
  final String groupCode;
  const NameInputScreen({
    super.key,
    required this.groupId,
    required this.groupCode,
  });
  @override
  State<NameInputScreen> createState() => _NameInputScreenState();
}

class _NameInputScreenState extends State<NameInputScreen> {
  final _ctrl = TextEditingController();
  bool _saving = false;
  String? _error;

  static const _palette = [
    '#D32F2F',
    '#1976D2',
    '#F57C00',
    '#7B1FA2',
    '#00796B',
    '#C2185B',
    '#5D4037',
    '#0288D1',
  ];

  String _randomColor() {
    final rnd = Random.secure();
    return _palette[rnd.nextInt(_palette.length)];
  }

  Future<void> _save() async {
    final name = _ctrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Введите имя');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final res = await Supabase.instance.client
          .from('hunters')
          .insert({
            'group_id': widget.groupId,
            'name': name,
            'color': _randomColor(),
          })
          .select('id, name')
          .single();
      await AppSession.save(
        groupId: widget.groupId,
        groupCode: widget.groupCode,
        hunterId: res['id'] as String,
        hunterName: res['name'] as String,
      );
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const MapScreen()),
        (_) => false,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Не удалось сохранить: $e';
        _saving = false;
      });
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ваше имя')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 32),
              Text(
                'Группа ${widget.groupCode}',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16, color: Colors.white70),
              ),
              const SizedBox(height: 24),
              const Text(
                'Как вас зовут в этой группе?',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              const Text(
                'Это имя увидят другие охотники вашей группы.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Colors.white60),
              ),
              const SizedBox(height: 32),
              TextField(
                controller: _ctrl,
                decoration: InputDecoration(
                  labelText: 'Имя',
                  border: const OutlineInputBorder(),
                  errorText: _error,
                ),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.check),
                label: const Text('Войти в группу'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
