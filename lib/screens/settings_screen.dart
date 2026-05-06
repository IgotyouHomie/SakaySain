import 'package:flutter/material.dart';
import 'developer_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black87),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Settings',
          style: TextStyle(
            color: Color(0xFF2E9E99),
            fontWeight: FontWeight.bold,
            fontSize: 22,
          ),
        ),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Column(
          children: [
            // Search bar
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFFF2F2F2),
                borderRadius: BorderRadius.circular(30),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: const Row(
                children: [
                  Icon(Icons.search, color: Colors.grey),
                  SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      decoration: InputDecoration(
                        hintText: 'search',
                        border: InputBorder.none,
                        hintStyle: TextStyle(color: Colors.grey),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            _SettingsTile(
              icon: Icons.person_outline,
              label: 'Profile',
              onTap: () {
                // TODO: Navigate to Profile screen
              },
            ),
            _SettingsTile(
              icon: Icons.bug_report_outlined,
              label: 'Stats for Nerds',
              onTap: () {
                // TODO: Navigate to Stats for Nerds screen
              },
            ),
            _SettingsTile(
              icon: Icons.developer_mode_outlined,
              label: 'Developer Mode',
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const DeveloperScreen()),
                );
              },
            ),
            _SettingsTile(
              icon: Icons.info_outline,
              label: 'About',
              onTap: () {
                // TODO: Navigate to About screen
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _SettingsTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(icon, color: Colors.black87, size: 24),
          title: Text(
            label,
            style: const TextStyle(fontSize: 16, color: Colors.black87),
          ),
          trailing: const Icon(Icons.chevron_right, color: Colors.black45),
          onTap: onTap,
        ),
        const Divider(height: 1, color: Color(0xFFEEEEEE)),
      ],
    );
  }
}
