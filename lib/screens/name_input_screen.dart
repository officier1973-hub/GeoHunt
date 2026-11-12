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
  String _selectedRole = 'shooter';

  // (код, название, цвет)
  static const _roles = [
    ('shooter', 'Стрелок', '#D32F2F'),
    ('driver', 'Загонщик', '#1976D2'),
    ('ranger', 'Егерь', '#FFA000'),
    ('none', 'Нет', '#7B1FA2'),
  ];

  String _colorForRole(String role) {
    for (final r in _roles) {
      if (r.$1 == role) return r.$3;
    }
    return '#1976D2';
  }

  Color _parseHex(String hex) {
    final h = hex.replaceAll('#', '');
    return Color(0xFF000000 | int.parse(h, radix: 16));
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
            'role': _selectedRole,
            'color': _colorForRole(_selectedRole),
          })
          .select('id, name, role')
          .single();
      await AppSession.save(
        groupId: widget.groupId,
        groupCode: widget.groupCode,
        hunterId: res['id'] as String,
        hunterName: res['name'] as String,
        hunterRole: (res['role'] as String?) ?? _selectedRole,
      );
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const MapScreen()),
        (_) => false,
      );
    } on PostgrestException catch (e) {
      if (!mounted) return;
      if (e.code == '23505') {
        setState(() {
          _error = 'Имя «$name» уже занято в этой группе. Выберите другое.';
          _saving = false;
        });
        return;
      }
      setState(() {
        _error = 'Не удалось сохранить: ${e.message}';
        _saving = false;
      });
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
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 16),
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
              const SizedBox(height: 8),
              const Text(
                'Это имя увидят другие охотники.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Colors.white60),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _ctrl,
                decoration: InputDecoration(
                  labelText: 'Имя',
                  border: const OutlineInputBorder(),
                  errorText: _error,
                ),
                textInputAction: TextInputAction.done,
              ),
              const SizedBox(height: 28),
              const Text(
                'Ваша роль',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              const Text(
                'Цвет кружка на карте у других охотников',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Colors.white60),
              ),
              const SizedBox(height: 12),
              ..._roles.map((r) {
                final selected = _selectedRole == r.$1;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: InkWell(
                    onTap: () => setState(() => _selectedRole = r.$1),
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: selected ? Colors.white : Colors.white24,
                          width: selected ? 2 : 1,
                        ),
                        borderRadius: BorderRadius.circular(12),
                        color: selected ? Colors.white10 : null,
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              color: _parseHex(r.$3),
                              shape: BoxShape.circle,
                              border: Border.all(
                                  color: Colors.white54, width: 2),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Text(
                            r.$2,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: selected
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                          const Spacer(),
                          if (selected)
                            const Icon(Icons.check, color: Colors.white),
                        ],
                      ),
                    ),
                  ),
                );
              }),
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
