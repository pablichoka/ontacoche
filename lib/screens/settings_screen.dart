import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/api_provider.dart';
import '../utils/scroll_utils.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final TextEditingController _nameController = TextEditingController();
  final FocusNode _nameFocus = FocusNode();
  final GlobalKey _nameFieldKey = GlobalKey();
  final ScrollController _scrollController = ScrollController();

  bool _isSaving = false;
  double _lastKeyboardHeight = 0.0;

  @override
  void initState() {
    super.initState();
    _nameFocus.addListener(_handleFocusChange);
  }

  void _handleFocusChange() {
    if (_nameFocus.hasFocus) {
      Future.delayed(const Duration(milliseconds: 450), _scrollToTextField);
    }
  }

  void _scrollToTextField() {
    if (!mounted) return;
    final box = _nameFieldKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;

    final media = MediaQuery.of(context);
    final keyboardHeight = media.viewInsets.bottom;
    if (keyboardHeight <= 0) return;

    final fieldGlobalY = box.localToGlobal(Offset.zero).dy;
    final fieldHeight = box.size.height;

    final desiredOffset = computeKeyboardScrollOffset(
      fieldGlobalY: fieldGlobalY,
      fieldHeight: fieldHeight,
      screenHeight: media.size.height,
      keyboardHeight: keyboardHeight,
      currentScrollOffset: _scrollController.offset,
      topInset: media.padding.top + kToolbarHeight,
      bottomInset: media.padding.bottom,
      extraPadding: 24,
    );

    if (desiredOffset == null) return;

    final clamped = desiredOffset.clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );

    _scrollController.animateTo(
      clamped,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _nameFocus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _saveDeviceName() async {
    final String newName = _nameController.text.trim();
    if (newName.isEmpty) return;

    setState(() => _isSaving = true);

    try {
      final service = ref.read(flespiApiServiceProvider);
      final selector = ref.read(deviceSelectorProvider);

      await service.updateDevice(selector, {'name': newName});

      // Hide the keyboard and remove focus (keeps cursor from staying active)
      if (mounted) FocusScope.of(context).unfocus();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            behavior: SnackBarBehavior.fixed,
            content: Text('Nombre actualizado correctamente'),
          ),
        );
        ref.invalidate(deviceDetailsProvider);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.fixed,
            content: Text('Error al actualizar: $e'),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final deviceState = ref.watch(deviceDetailsProvider);

    return Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: const Text(
          'Ajustes',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: deviceState.when(
        data: (device) {
          if (_nameController.text.isEmpty && !_isSaving) {
            _nameController.text = device['name'] ?? '';
          }

          // Detectar cuando se cierra el teclado y limpiar el foco
          final currentKeyboardHeight = MediaQuery.of(
            context,
          ).viewInsets.bottom;
          if (_lastKeyboardHeight > 0 &&
              currentKeyboardHeight == 0 &&
              _nameFocus.hasFocus) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              FocusScope.of(context).unfocus();
            });
          }
          _lastKeyboardHeight = currentKeyboardHeight;

          final media = MediaQuery.of(context);
          final viewInsets = media.viewInsets;
          final keyboardOpen = viewInsets.bottom > 0;

          if (!keyboardOpen && _scrollController.hasClients) {
            // No permitir scroll cuando el teclado está cerrado.
            _scrollController.jumpTo(0);
          }

          return Padding(
            padding: EdgeInsets.only(bottom: viewInsets.bottom),
            child: SingleChildScrollView(
              controller: _scrollController,
              physics: keyboardOpen
                  ? const ClampingScrollPhysics()
                  : const NeverScrollableScrollPhysics(),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildSectionTitle('Información del Dispositivo'),
                  _buildDeviceCard(device),
                  const SizedBox(height: 24),
                  _buildSectionTitle('Configuración'),
                  _buildSettingItem(
                    title: 'Nombre del Tracker',
                    subtitle: 'Personaliza cómo aparece el dispositivo',
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            key: _nameFieldKey,
                            focusNode: _nameFocus,
                            controller: _nameController,
                            decoration: InputDecoration(
                              hintText: 'Ej: Mi Coche',
                              filled: true,
                              fillColor: Colors.grey.shade100,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide.none,
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _isSaving
                            ? const CircularProgressIndicator()
                            : IconButton.filled(
                                onPressed: _saveDeviceName,
                                icon: const Icon(Icons.check_rounded),
                                style: IconButton.styleFrom(
                                  backgroundColor: const Color(0xFF1D4ED8),
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                              ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),
                  const Center(
                    child: Text(
                      'Ontacoche v1.2.0',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  ),
                  SizedBox(height: viewInsets.bottom + 100),
                ],
              ),
            ),
          );
        },

        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, stack) => Center(child: Text('Error: $err')),
      ),
    );
  }

  Widget _buildDeviceCard(Map<String, dynamic> device) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          _buildInfoRow('ID', device['id']?.toString() ?? '---'),
          const Divider(height: 24),
          _buildInfoRow('Protocolo', device['protocol_name'] ?? '---'),
          const Divider(height: 24),
          _buildInfoRow('Tipo', device['device_type_name'] ?? '---'),
          const Divider(height: 24),
          _buildInfoRow(
            'Estado',
            (device['connected'] ?? false) ? 'Conectado' : 'Desconectado',
            valueColor: (device['connected'] ?? false)
                ? Colors.green
                : Colors.red,
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value, {Color? valueColor}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.grey.shade600,
            fontWeight: FontWeight.w500,
          ),
        ),
        Text(
          value,
          style: TextStyle(fontWeight: FontWeight.bold, color: valueColor),
        ),
      ],
    );
  }

  Widget _buildSettingItem({
    required String title,
    required String subtitle,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 12),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: Colors.grey.shade600,
          letterSpacing: 1,
        ),
      ),
    );
  }
}
