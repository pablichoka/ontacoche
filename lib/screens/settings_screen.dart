import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/api_provider.dart';
import '../providers/settings_provider.dart';
import '../theme/app_colors.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _parkingController = TextEditingController();

  late final FocusNode _nameFocusNode;
  late final FocusNode _parkingFocusNode;

  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _nameFocusNode = FocusNode()
      ..addListener(() => _onFocusChange(_nameFocusNode));
    _parkingFocusNode = FocusNode()
      ..addListener(() => _onFocusChange(_parkingFocusNode));
  }

  void _onFocusChange(FocusNode node) async {
    if (!node.hasFocus) return;
    await Future.delayed(const Duration(milliseconds: 400));
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = node.context;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 250),
          alignment: 0.1,
        );
      }
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _parkingController.dispose();
    _nameFocusNode.dispose();
    _parkingFocusNode.dispose();
    super.dispose();
  }

  Future<void> _saveDeviceName() async {
    final String newName = _nameController.text.trim();
    if (newName.isEmpty) return;

    setState(() => _isSaving = true);

    try {
      final service = ref.read(vercelConnectorServiceProvider);
      final selector = ref.read(deviceSelectorProvider);

      await service.updateDeviceName(selector, newName);

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
    final settingsAsync = ref.watch(settingsRepositoryProvider);
    final double kbHeight = MediaQuery.of(context).viewInsets.bottom;

    return ColoredBox(
      color: AppColors.background,
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              color: AppColors.surface,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: const Text(
                'Ajustes',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 20,
                  color: Colors.white,
                  letterSpacing: -0.5,
                ),
              ),
            ),
            Expanded(
              child: deviceState.when(
                data: (device) {
                  if (_nameController.text.isEmpty && !_isSaving) {
                    _nameController.text = device['name'] ?? '';
                  }

                  return SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(16, 16, 16, kbHeight + 200),
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
                                  controller: _nameController,
                                  focusNode: _nameFocusNode,
                                  decoration: InputDecoration(
                                    hintText: 'Ej: Mi Coche',
                                    hintStyle: const TextStyle(
                                      color: AppColors.muted,
                                    ),
                                    filled: true,
                                    fillColor: AppColors.surface,
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
                                        backgroundColor: AppColors.brand,
                                        foregroundColor: AppColors.surface,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                      ),
                                    ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        _buildSectionTitle('Preferencias de Geovallas'),
                        settingsAsync.when(
                          data: (settings) {
                            if (_parkingController.text.isEmpty && !_isSaving) {
                              _parkingController.text = settings
                                  .parkingDiameterMeters
                                  .toStringAsFixed(0);
                            }
                            return _buildSettingItem(
                              title: 'Diámetro parking (m)',
                              subtitle:
                                  'Diámetro por defecto para geovallas tipo parking',
                              child: Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: _parkingController,
                                      focusNode: _parkingFocusNode,
                                      keyboardType:
                                          const TextInputType.numberWithOptions(
                                            decimal: false,
                                          ),
                                      decoration: InputDecoration(
                                        hintText: '100',
                                        hintStyle: const TextStyle(
                                          color: AppColors.muted,
                                        ),
                                        filled: true,
                                        fillColor: AppColors.surface,
                                        border: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                          borderSide: BorderSide.none,
                                        ),
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                              horizontal: 16,
                                              vertical: 12,
                                            ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  FilledButton.icon(
                                    onPressed: () async {
                                      final String raw = _parkingController.text
                                          .trim();
                                      final double? meters = double.tryParse(
                                        raw,
                                      );
                                      if (meters == null || meters <= 0) {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                              'Introduce un número válido.',
                                            ),
                                          ),
                                        );
                                        return;
                                      }
                                      try {
                                        await settings.setParkingDiameterMeters(
                                          meters,
                                        );
                                        ref.invalidate(
                                          settingsRepositoryProvider,
                                        );
                                        if (mounted) {
                                          FocusScope.of(context).unfocus();
                                        }
                                        if (mounted) {
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            const SnackBar(
                                              content: Text(
                                                'Preferencia guardada.',
                                              ),
                                            ),
                                          );
                                        }
                                      } catch (e) {
                                        if (mounted) {
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            SnackBar(
                                              content: Text('Error: $e'),
                                            ),
                                          );
                                        }
                                      }
                                    },
                                    icon: const Icon(Icons.save_rounded),
                                    label: const Text(
                                      'Guardar',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    style: FilledButton.styleFrom(
                                      backgroundColor: AppColors.brand,
                                      foregroundColor: AppColors.surface,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                          loading: () => _buildSettingItem(
                            title: 'Diámetro parking (m)',
                            subtitle: 'Cargando…',
                            child: const SizedBox(
                              height: 48,
                              child: Center(child: CircularProgressIndicator()),
                            ),
                          ),
                          error: (e, s) => _buildSettingItem(
                            title: 'Diámetro parking (m)',
                            subtitle: 'Error cargando preferencias',
                            child: Text('Error: $e'),
                          ),
                        ),
                        const SizedBox(height: 32),
                        const Center(
                          child: Text(
                            'Ontacoche v1.2.0',
                            style: TextStyle(
                              color: AppColors.muted,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        const SizedBox(height: 32),
                      ],
                    ),
                  );
                },
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (err, stack) => Center(child: Text('Error: $err')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceCard(Map<String, dynamic> device) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: AppColors.brand.withValues(alpha: 0.04),
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
                ? AppColors.success
                : AppColors.danger,
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
          style: const TextStyle(
            color: AppColors.muted,
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
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: AppColors.brand.withValues(alpha: 0.04),
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
            style: const TextStyle(color: AppColors.muted, fontSize: 13),
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
          color: AppColors.muted,
          letterSpacing: 1,
        ),
      ),
    );
  }
}
