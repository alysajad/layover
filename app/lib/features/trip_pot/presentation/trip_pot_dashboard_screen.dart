import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/theme.dart';

enum BackendStatusTone { demo, ready, warning }

class BackendStatus {
  const BackendStatus({
    required this.label,
    required this.detail,
    required this.tone,
  });

  const BackendStatus.loading()
    : label = 'Checking setup',
      detail = 'Looking for Supabase and the trip tables.',
      tone = BackendStatusTone.demo;

  final String label;
  final String detail;
  final BackendStatusTone tone;

  bool get isLoading => label == 'Checking setup';
}

class TripPotDashboardScreen extends StatefulWidget {
  const TripPotDashboardScreen({required this.status, super.key});

  final BackendStatus status;

  @override
  State<TripPotDashboardScreen> createState() => _TripPotDashboardScreenState();
}

class _TripPotDashboardScreenState extends State<TripPotDashboardScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion;

  int _selectedNav = 0;
  int _confirmed = 84000;
  int _paid = 7;
  int _pending = 3;
  int _inviteCount = 10;
  int _friendSeed = 0;
  final List<String> _activity = [
    'Mira confirmed INR 12,000',
    'Invite code refreshed',
    'Target is 70% ready',
  ];

  double get _progress => (_confirmed / 120000).clamp(0, 1).toDouble();
  int get _remaining => math.max(0, 120000 - _confirmed);

  @override
  void initState() {
    super.initState();
    _motion = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 5200),
    )..repeat();
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  void _show(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(milliseconds: 1200),
        ),
      );
  }

  void _inviteFriend() {
    setState(() {
      _inviteCount++;
      _pending++;
      _friendSeed++;
      _activity.insert(0, 'New invite sent to friend #$_inviteCount');
      if (_activity.length > 5) _activity.removeLast();
    });
    _show('Invite link ready');
  }

  void _recordContribution() {
    if (_confirmed >= 120000) {
      _show('Target already reached');
      return;
    }
    setState(() {
      _confirmed = math.min(120000, _confirmed + 12000);
      _paid++;
      _pending = math.max(0, _pending - 1);
      _activity.insert(0, 'Recorded INR 12,000 contribution');
      if (_activity.length > 5) _activity.removeLast();
    });
    _show(
      _confirmed >= 120000 ? 'Funding target reached' : 'Contribution recorded',
    );
  }

  void _selectNav(int index) {
    setState(() => _selectedNav = index);
    _show(['Home', 'Friends', 'Payments', 'Profile'][index]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AnimatedBuilder(
        animation: _motion,
        builder: (context, child) {
          return CustomPaint(
            painter: _DoodleBackgroundPainter(_motion.value),
            child: child,
          );
        },
        child: SafeArea(
          child: CustomScrollView(
            slivers: [
              SliverAppBar(
                pinned: true,
                backgroundColor: LayoverColors.paper.withValues(alpha: 0.94),
                titleSpacing: 20,
                title: _BrandHeader(motion: _motion),
                actions: [
                  Tooltip(
                    message: 'Notifications',
                    child: IconButton(
                      onPressed: () => _show('No new trip nudges'),
                      icon: const Icon(Icons.notifications_none_rounded),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
                sliver: SliverList.list(
                  children: [
                    _BackendBanner(status: widget.status),
                    const SizedBox(height: 14),
                    _TabDoodleStrip(selected: _selectedNav),
                    const SizedBox(height: 14),
                    _HeroPotCard(
                      confirmed: _confirmed,
                      paid: _paid,
                      pending: _pending,
                      progress: _progress,
                      motion: _motion,
                    ),
                    const SizedBox(height: 14),
                    _QuickActions(
                      onInvite: _inviteFriend,
                      onRecord: _recordContribution,
                    ),
                    const SizedBox(height: 14),
                    _SplitCards(remaining: _remaining),
                    const SizedBox(height: 14),
                    _ParticipantsCard(
                      count: _inviteCount,
                      seed: _friendSeed,
                      onAdd: _inviteFriend,
                    ),
                    const SizedBox(height: 14),
                    _ActivityCard(items: _activity),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: _DoodleNavigationBar(
        selected: _selectedNav,
        onChanged: _selectNav,
      ),
    );
  }
}

class _BrandHeader extends StatelessWidget {
  const _BrandHeader({required this.motion});

  final Animation<double> motion;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _Wiggle(
          motion: motion,
          amount: 0.05,
          child: const _StampIcon(icon: Icons.flight_takeoff_rounded),
        ),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Layover', style: Theme.of(context).textTheme.titleLarge),
            Text(
              'Group trip pot',
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ],
        ),
      ],
    );
  }
}

class _BackendBanner extends StatelessWidget {
  const _BackendBanner({required this.status});

  final BackendStatus status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status.tone) {
      BackendStatusTone.demo => LayoverColors.blue,
      BackendStatusTone.ready => LayoverColors.mint,
      BackendStatusTone.warning => LayoverColors.coral,
    };

    return _InkCard(
      color: color.withValues(alpha: 0.2),
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          if (status.isLoading)
            const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            )
          else
            Icon(
              status.tone == BackendStatusTone.ready
                  ? Icons.check_circle_outline_rounded
                  : Icons.info_outline_rounded,
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  status.label,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                Text(
                  status.detail,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TabDoodleStrip extends StatelessWidget {
  const _TabDoodleStrip({required this.selected});

  final int selected;

  @override
  Widget build(BuildContext context) {
    final labels = ['Trip', 'Friends', 'Money', 'You'];
    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: labels.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final active = selected == index;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutBack,
            padding: EdgeInsets.symmetric(horizontal: active ? 18 : 13),
            decoration: BoxDecoration(
              color: active ? LayoverColors.mango : Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: LayoverColors.ink, width: 1.4),
            ),
            child: Center(
              child: Text(
                labels[index],
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _HeroPotCard extends StatelessWidget {
  const _HeroPotCard({
    required this.confirmed,
    required this.paid,
    required this.pending,
    required this.progress,
    required this.motion,
  });

  final int confirmed;
  final int paid;
  final int pending;
  final double progress;
  final Animation<double> motion;

  @override
  Widget build(BuildContext context) {
    return _BouncyTap(
      onTap: () {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('Tap Record to move the pot'),
              behavior: SnackBarBehavior.floating,
            ),
          );
      },
      child: _InkCard(
        color: Colors.white,
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Goa villa weekend',
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Target closes on 18 Oct',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
                _Wiggle(
                  motion: motion,
                  amount: 0.03,
                  child: const _CountdownBadge(days: 8),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  'INR ${_money(confirmed)}',
                  style: Theme.of(context).textTheme.displaySmall,
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '/ 120,000',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            AnimatedBuilder(
              animation: motion,
              builder: (context, _) {
                return _DoodleProgress(value: progress, phase: motion.value);
              },
            ),
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 360;
                final children = [
                  const _MetricPill(
                    icon: Icons.verified_rounded,
                    label: '',
                    color: LayoverColors.mint,
                  ),
                  const _MetricPill(
                    icon: Icons.hourglass_bottom_rounded,
                    label: '',
                    color: LayoverColors.mango,
                  ),
                  const _MetricPill(
                    icon: Icons.payments_outlined,
                    label: 'INR 12k each',
                    color: LayoverColors.lilac,
                  ),
                ];
                final labels = [
                  '$paid paid',
                  '$pending pending',
                  'INR 12k each',
                ];

                return compact
                    ? Column(
                        children: [
                          for (var i = 0; i < children.length; i++)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: _MetricPill(
                                icon: children[i].icon,
                                label: labels[i],
                                color: children[i].color,
                              ),
                            ),
                        ],
                      )
                    : Row(
                        children: [
                          for (var i = 0; i < children.length; i++)
                            Expanded(
                              child: _MetricPill(
                                icon: children[i].icon,
                                label: labels[i],
                                color: children[i].color,
                              ),
                            ),
                        ],
                      );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _CountdownBadge extends StatelessWidget {
  const _CountdownBadge({required this.days});

  final int days;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 74,
      height: 74,
      decoration: BoxDecoration(
        color: LayoverColors.coral,
        shape: BoxShape.circle,
        border: Border.all(color: LayoverColors.ink, width: 1.5),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$days', style: Theme.of(context).textTheme.headlineMedium),
            Text('days', style: Theme.of(context).textTheme.labelMedium),
          ],
        ),
      ),
    );
  }
}

class _DoodleProgress extends StatelessWidget {
  const _DoodleProgress({required this.value, required this.phase});

  final double value;
  final double phase;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 34,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: value),
        duration: const Duration(milliseconds: 520),
        curve: Curves.easeOutBack,
        builder: (context, animated, _) {
          return CustomPaint(
            painter: _ProgressPainter(animated, phase),
            child: Align(
              alignment: Alignment.center,
              child: Text(
                '${(animated * 100).round()}%',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _BouncyTap extends StatefulWidget {
  const _BouncyTap({required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  State<_BouncyTap> createState() => _BouncyTapState();
}

class _BouncyTapState extends State<_BouncyTap> {
  var _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) => setState(() => _down = false),
      child: AnimatedScale(
        scale: _down ? 0.985 : 1,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

class _Wiggle extends StatelessWidget {
  const _Wiggle({
    required this.motion,
    required this.child,
    this.amount = 0.04,
  });

  final Animation<double> motion;
  final Widget child;
  final double amount;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: motion,
      child: child,
      builder: (context, child) {
        final angle = math.sin(motion.value * math.pi * 2) * amount;
        return Transform.rotate(angle: angle, child: child);
      },
    );
  }
}

String _money(int amount) {
  final text = amount.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final remaining = text.length - i;
    buffer.write(text[i]);
    if (remaining > 1 && remaining % 3 == 1) buffer.write(',');
  }
  return buffer.toString();
}

class _AnimatedButton extends StatefulWidget {
  const _AnimatedButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onPressed;

  @override
  State<_AnimatedButton> createState() => _AnimatedButtonState();
}

class _AnimatedButtonState extends State<_AnimatedButton> {
  var _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onPressed,
      onTapDown: (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) => setState(() => _down = false),
      child: AnimatedScale(
        scale: _down ? 0.94 : 1,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: Container(
          height: 58,
          decoration: BoxDecoration(
            color: widget.color,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: LayoverColors.ink, width: 1.8),
            boxShadow: const [
              BoxShadow(
                color: Color(0x26171717),
                offset: Offset(0, 5),
                blurRadius: 0,
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(widget.icon),
              const SizedBox(width: 9),
              Text(widget.label, style: Theme.of(context).textTheme.labelLarge),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetricPill extends StatelessWidget {
  const _MetricPill({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: LayoverColors.ink, width: 1.3),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 17),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickActions extends StatelessWidget {
  const _QuickActions({required this.onInvite, required this.onRecord});

  final VoidCallback onInvite;
  final VoidCallback onRecord;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _AnimatedButton(
            onPressed: onInvite,
            icon: Icons.person_add_alt_1_rounded,
            label: 'Invite',
            color: LayoverColors.mango,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _AnimatedButton(
            onPressed: onRecord,
            icon: Icons.add_card_rounded,
            label: 'Record',
            color: LayoverColors.blue,
          ),
        ),
      ],
    );
  }
}

class _SplitCards extends StatelessWidget {
  const _SplitCards({required this.remaining});

  final int remaining;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth > 620;
        final cards = [
          _TinyStatCard(
            icon: Icons.account_balance_wallet_outlined,
            title: 'Remaining',
            value: 'INR ${_money(remaining)}',
            color: LayoverColors.mango,
          ),
          const _TinyStatCard(
            icon: Icons.receipt_long_outlined,
            title: 'Policy',
            value: 'Refundable before deadline',
            color: LayoverColors.blue,
          ),
          const _TinyStatCard(
            icon: Icons.lock_clock_outlined,
            title: 'Provider',
            value: 'Mock checkout',
            color: LayoverColors.mint,
          ),
        ];

        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final card in cards)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: card,
                  ),
                ),
            ],
          );
        }

        return Column(
          children: [
            for (final card in cards)
              Padding(padding: const EdgeInsets.only(bottom: 10), child: card),
          ],
        );
      },
    );
  }
}

class _TinyStatCard extends StatelessWidget {
  const _TinyStatCard({
    required this.icon,
    required this.title,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String title;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return _InkCard(
      color: color.withValues(alpha: 0.34),
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          _StampIcon(icon: icon, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.labelMedium),
                const SizedBox(height: 2),
                Text(value, style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ParticipantsCard extends StatelessWidget {
  const _ParticipantsCard({
    required this.count,
    required this.seed,
    required this.onAdd,
  });

  final int count;
  final int seed;
  final VoidCallback onAdd;

  static const _people = [
    ('Aarav', 'Paid', LayoverColors.mint, 1.0),
    ('Mira', 'Paid', LayoverColors.mint, 1.0),
    ('Zoya', 'Processing', LayoverColors.blue, 0.62),
    ('Kabir', 'Pending', LayoverColors.mango, 0.28),
    ('Dev', 'Pending', LayoverColors.coral, 0.16),
  ];

  @override
  Widget build(BuildContext context) {
    final people = [
      ..._people,
      if (seed > 0) ('Nia', 'Invited', LayoverColors.lilac, 0.18),
      if (seed > 1) ('Ishaan', 'Invited', LayoverColors.mango, 0.18),
      if (seed > 2) ('Rey', 'Invited', LayoverColors.blue, 0.18),
    ];

    return _InkCard(
      color: Colors.white,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Friends $count',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              TextButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 142,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: people.length,
              separatorBuilder: (context, index) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final (name, status, color, fill) = people[index];
                return _FriendMeter(
                  name: name,
                  status: status,
                  color: color,
                  fill: fill,
                  rank: index + 1,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _FriendMeter extends StatelessWidget {
  const _FriendMeter({
    required this.name,
    required this.status,
    required this.color,
    required this.fill,
    required this.rank,
  });

  final String name;
  final String status;
  final Color color;
  final double fill;
  final int rank;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 76,
      child: Column(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: color,
            child: Text(
              name.characters.first,
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            name,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelMedium,
          ),
          const SizedBox(height: 7),
          Expanded(
            child: Container(
              width: 42,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(13),
                border: Border.all(color: LayoverColors.ink, width: 1.3),
              ),
              alignment: Alignment.bottomCenter,
              clipBehavior: Clip.antiAlias,
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: fill),
                duration: Duration(milliseconds: 460 + rank * 80),
                curve: Curves.easeOutBack,
                builder: (context, animated, _) {
                  return FractionallySizedBox(
                    heightFactor: animated,
                    widthFactor: 1,
                    alignment: Alignment.bottomCenter,
                    child: ColoredBox(color: color),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '#$rank $status',
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelMedium,
          ),
        ],
      ),
    );
  }
}

class _ActivityCard extends StatelessWidget {
  const _ActivityCard({required this.items});

  final List<String> items;

  @override
  Widget build(BuildContext context) {
    return _InkCard(
      color: LayoverColors.lilac.withValues(alpha: 0.34),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Pot activity', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          for (var i = 0; i < items.length; i++)
            TweenAnimationBuilder<double>(
              key: ValueKey(items[i]),
              tween: Tween(begin: 0.92, end: 1),
              duration: Duration(milliseconds: 220 + i * 60),
              curve: Curves.easeOutBack,
              builder: (context, scale, child) {
                return Transform.scale(scale: scale, child: child);
              },
              child: _ActivityRow(
                icon: i == 0
                    ? Icons.auto_awesome_rounded
                    : Icons.check_circle_outline_rounded,
                title: items[i],
                time: i == 0 ? 'Now' : '${i + 1}h',
              ),
            ),
        ],
      ),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({
    required this.icon,
    required this.title,
    required this.time,
  });

  final IconData icon;
  final String title;
  final String time;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(icon, size: 21),
          const SizedBox(width: 10),
          Expanded(
            child: Text(title, style: Theme.of(context).textTheme.bodyMedium),
          ),
          Text(time, style: Theme.of(context).textTheme.labelMedium),
        ],
      ),
    );
  }
}

class _DoodleNavigationBar extends StatelessWidget {
  const _DoodleNavigationBar({required this.selected, required this.onChanged});

  final int selected;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
        child: _InkCard(
          color: LayoverColors.mint,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _NavItem(
                icon: Icons.home_rounded,
                selected: selected == 0,
                onTap: () => onChanged(0),
              ),
              _NavItem(
                icon: Icons.group_outlined,
                selected: selected == 1,
                onTap: () => onChanged(1),
              ),
              _NavItem(
                icon: Icons.credit_card_rounded,
                selected: selected == 2,
                onTap: () => onChanged(2),
              ),
              _NavItem(
                icon: Icons.person_outline_rounded,
                selected: selected == 3,
                onTap: () => onChanged(3),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutBack,
        width: selected ? 58 : 46,
        height: 40,
        decoration: selected
            ? BoxDecoration(
                color: LayoverColors.mango,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: LayoverColors.ink, width: 1.2),
              )
            : null,
        child: Icon(icon, color: selected ? LayoverColors.ink : Colors.white),
      ),
    );
  }
}

class _InkCard extends StatelessWidget {
  const _InkCard({
    required this.child,
    this.color = Colors.white,
    this.padding = const EdgeInsets.all(16),
  });

  final Widget child;
  final Color color;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: LayoverColors.ink, width: 1.5),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1F171717),
            offset: Offset(0, 8),
            blurRadius: 0,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

class _StampIcon extends StatelessWidget {
  const _StampIcon({required this.icon, this.color = LayoverColors.mint});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: LayoverColors.ink, width: 1.4),
      ),
      child: Icon(icon, size: 20),
    );
  }
}

class _ProgressPainter extends CustomPainter {
  const _ProgressPainter(this.value, this.phase);

  final double value;
  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    final track = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(18),
    );
    final fill = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.width * value, size.height),
      const Radius.circular(18),
    );

    canvas.drawRRect(
      track,
      Paint()
        ..style = PaintingStyle.fill
        ..color = Colors.white,
    );
    canvas.drawRRect(
      fill,
      Paint()
        ..style = PaintingStyle.fill
        ..color = LayoverColors.coral,
    );
    canvas.drawRRect(
      track,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..color = LayoverColors.ink,
    );

    final dotPaint = Paint()
      ..color = LayoverColors.ink.withValues(alpha: 0.35)
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    for (var x = 12.0 + phase * 17; x < size.width - 12; x += 17) {
      canvas.drawLine(
        Offset(x, size.height + 7),
        Offset(x + 3, size.height + 7),
        dotPaint,
      );
    }

    final dashPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.5)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    for (var x = -20.0 + phase * 40; x < size.width * value; x += 40) {
      canvas.drawLine(Offset(x, 7), Offset(x + 12, 15), dashPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _ProgressPainter oldDelegate) {
    return oldDelegate.value != value || oldDelegate.phase != phase;
  }
}

class _DoodleBackgroundPainter extends CustomPainter {
  const _DoodleBackgroundPainter(this.phase);

  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    final wash = Paint()..style = PaintingStyle.fill;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = Colors.white.withValues(alpha: 0.72);

    void drawOrb(Offset center, double radius, Color color) {
      canvas.drawCircle(
        center,
        radius,
        wash..color = color.withValues(alpha: 0.22),
      );
      for (var i = 0; i < 4; i++) {
        canvas.drawArc(
          Rect.fromCircle(center: center, radius: radius - i * 28),
          math.pi * (1.05 + phase * 0.18),
          math.pi * 1.55,
          false,
          stroke,
        );
      }
    }

    final drift = math.sin(phase * math.pi * 2);
    drawOrb(
      Offset(size.width * 0.18 + drift * 12, 36),
      126,
      LayoverColors.mint,
    );
    drawOrb(
      Offset(size.width * 0.9, size.height * 0.32 + drift * 18),
      92,
      LayoverColors.mango,
    );
    drawOrb(
      Offset(size.width * 0.5 - drift * 16, size.height - 6),
      96,
      LayoverColors.coral,
    );

    final dotPaint = Paint()
      ..color = LayoverColors.lilac.withValues(alpha: 0.55);
    canvas.drawCircle(Offset(34 + drift * 5, size.height * 0.58), 19, dotPaint);
    canvas.drawCircle(Offset(size.width - 28, 96), 9, dotPaint);
  }

  @override
  bool shouldRepaint(covariant _DoodleBackgroundPainter oldDelegate) {
    return oldDelegate.phase != phase;
  }
}
