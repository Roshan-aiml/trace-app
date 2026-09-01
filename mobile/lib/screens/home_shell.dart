import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../state/auth.dart';
import 'history_screen.dart';
import 'manager/manager_audit_trail_screen.dart';
import 'manager/manager_inspections_screen.dart';
import 'manager/manager_review_queue_screen.dart';
import 'manager/manager_session_summary_screen.dart';
import 'scan_screen.dart';
import 'sessions_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _managerIndex = 0;
  int _workerIndex = 0;
  int _pendingReviewCount = 0;
  Timer? _badgeTimer;

  @override
  void initState() {
    super.initState();
    _fetchReviewBadge();
    _badgeTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted && context.read<AuthState>().isManager) {
        _fetchReviewBadge();
      }
    });
  }

  @override
  void dispose() {
    _badgeTimer?.cancel();
    super.dispose();
  }

  Future<void> _fetchReviewBadge() async {
    try {
      final auth = context.read<AuthState>();
      if (!auth.isManager) return;
      final res = await auth.api.reviewQueue(fieldLabels: auth.fieldLabels);
      if (mounted) {
        setState(() => _pendingReviewCount = res.totalPending);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    final isManager = auth.isManager;

    if (isManager) {
      return _ManagerShell(
        selectedIndex: _managerIndex,
        pendingReviewCount: _pendingReviewCount,
        onSelectIndex: (i) {
          setState(() => _managerIndex = i);
          if (i == 3) {
            _fetchReviewBadge();
          }
        },
      );
    }

    // Health Inspector UI (Scan, History, Sessions, More)
    final workerPages = const [
      ScanScreen(),
      HistoryScreen(),
      SessionsScreen(),
      _WorkerMoreScreen(),
    ];

    final safeIndex = _workerIndex < workerPages.length ? _workerIndex : 0;

    return Scaffold(
      body: IndexedStack(index: safeIndex, children: workerPages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: safeIndex,
        onDestinationSelected: (i) => setState(() => _workerIndex = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.document_scanner_outlined),
            selectedIcon: Icon(Icons.document_scanner),
            label: 'Scan',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_outlined),
            selectedIcon: Icon(Icons.history),
            label: 'History',
          ),
          NavigationDestination(
            icon: Icon(Icons.inventory_2_outlined),
            selectedIcon: Icon(Icons.inventory_2),
            label: 'Sessions',
          ),
          NavigationDestination(
            icon: Icon(Icons.more_horiz),
            label: 'More',
          ),
        ],
      ),
    );
  }
}

/// Manager Portal with dedicated Sidebar matching TRACE AI visual language.
class _ManagerShell extends StatelessWidget {
  final int selectedIndex;
  final int pendingReviewCount;
  final ValueChanged<int> onSelectIndex;

  const _ManagerShell({
    required this.selectedIndex,
    required this.pendingReviewCount,
    required this.onSelectIndex,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isWide = MediaQuery.of(context).size.width >= 760;

    final managerPages = [
      const ManagerInspectionsScreen(),
      const ManagerSessionSummaryScreen(),
      const ManagerAuditTrailScreen(),
      const ManagerReviewQueueScreen(),
      const _ManagerProfileScreen(),
    ];

    final safeIndex = selectedIndex < managerPages.length ? selectedIndex : 0;

    if (isWide) {
      return Scaffold(
        body: Row(
          children: [
            // Fixed Left Sidebar
            SizedBox(
              width: 260,
              child: _ManagerSidebar(
                selectedIndex: safeIndex,
                pendingReviewCount: pendingReviewCount,
                onSelectIndex: onSelectIndex,
              ),
            ),
            VerticalDivider(width: 1, color: scheme.outlineVariant),
            // Page Body
            Expanded(
              child: IndexedStack(
                index: safeIndex,
                children: managerPages,
              ),
            ),
          ],
        ),
      );
    }

    // Mobile / Narrow layout with Drawer & Bottom Nav
    return Scaffold(
      drawer: Drawer(
        child: SafeArea(
          child: _ManagerSidebar(
            selectedIndex: safeIndex,
            pendingReviewCount: pendingReviewCount,
            onSelectIndex: (i) {
              Navigator.of(context).pop();
              onSelectIndex(i);
            },
          ),
        ),
      ),
      body: IndexedStack(
        index: safeIndex,
        children: managerPages,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: safeIndex,
        onDestinationSelected: onSelectIndex,
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.fact_check_outlined),
            selectedIcon: Icon(Icons.fact_check),
            label: 'Inspections',
          ),
          const NavigationDestination(
            icon: Icon(Icons.assessment_outlined),
            selectedIcon: Icon(Icons.assessment),
            label: 'Session',
          ),
          const NavigationDestination(
            icon: Icon(Icons.receipt_long_outlined),
            selectedIcon: Icon(Icons.receipt_long),
            label: 'Audit',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: pendingReviewCount > 0,
              label: Text('$pendingReviewCount'),
              backgroundColor: const Color(0xFFB3261E),
              child: const Icon(Icons.rate_review_outlined),
            ),
            selectedIcon: Badge(
              isLabelVisible: pendingReviewCount > 0,
              label: Text('$pendingReviewCount'),
              backgroundColor: const Color(0xFFB3261E),
              child: const Icon(Icons.rate_review),
            ),
            label: 'Review',
          ),
          const NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Account',
          ),
        ],
      ),
    );
  }
}

class _ManagerSidebar extends StatelessWidget {
  final int selectedIndex;
  final int pendingReviewCount;
  final ValueChanged<int> onSelectIndex;

  const _ManagerSidebar({
    required this.selectedIndex,
    required this.pendingReviewCount,
    required this.onSelectIndex,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final auth = context.watch<AuthState>();
    final u = auth.user;

    return Container(
      color: scheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Branding Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.qr_code_scanner,
                      size: 24, color: scheme.primary),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'TRACE AI',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                          ),
                    ),
                    Text(
                      'Manager Portal',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          // Section Title: REPORTS & AUDIT
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: Text(
              'REPORTS & AUDIT',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.1,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
              ),
            ),
          ),

          // 4 Manager Nav Items
          _SidebarItem(
            icon: Icons.fact_check_outlined,
            activeIcon: Icons.fact_check,
            title: 'Inspections',
            selected: selectedIndex == 0,
            onTap: () => onSelectIndex(0),
          ),
          _SidebarItem(
            icon: Icons.assessment_outlined,
            activeIcon: Icons.assessment,
            title: 'Session Summary',
            selected: selectedIndex == 1,
            onTap: () => onSelectIndex(1),
          ),
          _SidebarItem(
            icon: Icons.receipt_long_outlined,
            activeIcon: Icons.receipt_long,
            title: 'Audit Trail',
            selected: selectedIndex == 2,
            onTap: () => onSelectIndex(2),
          ),
          _SidebarItem(
            icon: Icons.rate_review_outlined,
            activeIcon: Icons.rate_review,
            title: 'Review Queue',
            badgeCount: pendingReviewCount,
            selected: selectedIndex == 3,
            onTap: () => onSelectIndex(3),
          ),

          const Spacer(),
          const Divider(height: 1),

          // User info and Logout Footer
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                InkWell(
                  onTap: () => onSelectIndex(4),
                  borderRadius: BorderRadius.circular(10),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 18,
                          backgroundColor: scheme.primary.withValues(alpha: 0.15),
                          child: Text(
                            (u?.email ?? 'M').substring(0, 1).toUpperCase(),
                            style: TextStyle(
                                color: scheme.primary,
                                fontWeight: FontWeight.w700),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                u?.fullName?.isNotEmpty == true
                                    ? u!.fullName!
                                    : (u?.email ?? 'Manager'),
                                style: const TextStyle(
                                    fontSize: 13, fontWeight: FontWeight.w600),
                                overflow: TextOverflow.ellipsis,
                              ),
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 5, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: scheme.primary.withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      'Manager',
                                      style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700,
                                          color: scheme.primary),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: scheme.error,
                      side: BorderSide(
                          color: scheme.error.withValues(alpha: 0.4)),
                    ),
                    onPressed: () => context.read<AuthState>().logout(),
                    icon: const Icon(Icons.logout, size: 16),
                    label: const Text('Sign Out'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  final IconData icon;
  final IconData activeIcon;
  final String title;
  final bool selected;
  final int? badgeCount;
  final VoidCallback onTap;

  const _SidebarItem({
    required this.icon,
    required this.activeIcon,
    required this.title,
    required this.selected,
    this.badgeCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Material(
        color: selected
            ? scheme.primary.withValues(alpha: 0.12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(
                  selected ? activeIcon : icon,
                  size: 20,
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight:
                          selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected ? scheme.primary : scheme.onSurface,
                    ),
                  ),
                ),
                if (badgeCount != null && badgeCount! > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFFB3261E),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '$badgeCount',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ManagerProfileScreen extends StatelessWidget {
  const _ManagerProfileScreen();

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    final u = auth.user;

    return Scaffold(
      appBar: AppBar(title: const Text('Manager Account')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: CircleAvatar(
                child: Text((u?.email ?? 'M').substring(0, 1).toUpperCase()),
              ),
              title: Text(u?.fullName?.isNotEmpty == true
                  ? u!.fullName!
                  : (u?.email ?? '')),
              subtitle: Text('${u?.email ?? ''} • Manager'),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: const Text('API Server Endpoint'),
              subtitle: Text(auth.baseUrl),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.tonalIcon(
            style: FilledButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => context.read<AuthState>().logout(),
            icon: const Icon(Icons.logout),
            label: const Text('Sign out of TRACE'),
          ),
        ],
      ),
    );
  }
}

class _WorkerMoreScreen extends StatelessWidget {
  const _WorkerMoreScreen();

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    final app = context.watch<AppState>();
    final u = auth.user;

    return Scaffold(
      appBar: AppBar(title: const Text('More')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: ListTile(
              leading: CircleAvatar(
                child: Text((u?.email ?? '?').substring(0, 1).toUpperCase()),
              ),
              title: Text(u?.fullName?.isNotEmpty == true
                  ? u!.fullName!
                  : (u?.email ?? '')),
              subtitle: Text('${u?.email ?? ''} · Health Inspector'),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.inventory_2_outlined),
              title: const Text('Active session'),
              subtitle: Text(app.activeSession?.name ?? 'none selected'),
              trailing: app.activeSession != null
                  ? TextButton(
                      onPressed: () => app.setActiveSession(null),
                      child: const Text('Clear'))
                  : null,
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: const Text('API server'),
              subtitle: Text(auth.baseUrl),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            style: FilledButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => context.read<AuthState>().logout(),
            icon: const Icon(Icons.logout),
            label: const Text('Sign out'),
          ),
        ],
      ),
    );
  }
}
