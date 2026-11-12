import 'dart:math';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'name_input_screen.dart';

class CreateGroupScreen extends StatefulWidget {
  const CreateGroupScreen({super.key});
  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  bool _creating = true;
  String? _code;
  String? _groupId;
  String? _error;

  @override
  void initState() {
    super.initState();
    _createGroup();
  }

  String _generateCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rnd = Random.secure();
    return List.generate(4, (_) => chars[rnd.nextInt(chars.length)]).join();
  }

  Future<void> _createGroup() async {
    final supabase = Supabase.instance.client;
    String? lastError;
    for (int attempt = 0; attempt < 5; attempt++) {
      final code = _generateCode();
      try {
        final res = await supabase
            .from('groups')
            .insert({'code': code})
            .select('id, code')
            .single();
        if (mounted) {
          setState(() {
            _groupId = res['id'] as String;
            _code = res['code'] as String;
            _creating = false;
          });
        }
        return;
      } on PostgrestException catch (e) {
        if (e.code == '23505') {
          lastError = 'code collision';
          continue;
        }
        lastError = e.message;
        break;
      } catch (e) {
        lastError = e.toString();
        break;
      }
    }
    if (mounted) {
      setState(() {
        _error = 'Не удалось создать группу: $lastError';
        _creating = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Создание группы')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _creating
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Назад'),
                        ),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: 32),
                        const Text(
                          'Группа создана',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 24, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 24),
                        const Text(
                          'Код вашей группы:',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 16, color: Colors.white70),
                        ),
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              vertical: 24, horizontal: 16),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E1E1E),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.white24),
                          ),
                          child: Text(
                            _code ?? '',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 48,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 12,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'Передайте этот код другим охотникам, чтобы они могли присоединиться.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 14, color: Colors.white60),
                        ),
                        const Spacer(),
                        FilledButton.icon(
                          icon: const Icon(Icons.arrow_forward),
                          label: const Text('Продолжить'),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                          onPressed: () {
                            Navigator.of(context).pushReplacement(
                              MaterialPageRoute(
                                builder: (_) => NameInputScreen(
                                  groupId: _groupId!,
                                  groupCode: _code!,
                                ),
                              ),
                            );
                          },
                        ),
                        const Spacer(flex: 2),
                      ],
                    ),
        ),
      ),
    );
  }
}
