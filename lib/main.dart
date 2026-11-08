import 'package:flutter/material.dart';

import 'src/app_services.dart';
import 'src/ui/app_theme.dart';
import 'src/ui/bootstrap_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProotBoxApp());
}

class ProotBoxApp extends StatefulWidget {
  const ProotBoxApp({super.key});

  @override
  State<ProotBoxApp> createState() => _ProotBoxAppState();
}

class _ProotBoxAppState extends State<ProotBoxApp> {
  late final Future<AppServices> _services = AppServices.bootstrap();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ProotBox',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: FutureBuilder<AppServices>(
        future: _services,
        builder: (BuildContext context, AsyncSnapshot<AppServices> snapshot) {
          if (snapshot.hasError) {
            return StartupErrorScreen(error: snapshot.error!);
          }
          final AppServices? services = snapshot.data;
          if (services == null) {
            return const Scaffold(
              body: Center(
                child: SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          return BootstrapScreen(services: services);
        },
      ),
    );
  }
}
