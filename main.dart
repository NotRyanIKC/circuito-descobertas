import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

final db = FirebaseFirestore.instance;
final analytics = FirebaseAnalytics.instance;
final rc = FirebaseRemoteConfig.instance;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  // Visitante entra com sessao anonima
  if (FirebaseAuth.instance.currentUser == null) {
    await FirebaseAuth.instance.signInAnonymously();
  }

  // Remote Config: padrao local com a missao desligada
  await rc.setConfigSettings(RemoteConfigSettings(
    fetchTimeout: const Duration(seconds: 10),
    minimumFetchInterval: Duration.zero,
  ));
  await rc.setDefaults({'missao_ativa': false, 'estandes_destaque': ''});
  try {
    await rc.fetchAndActivate();
  } catch (_) {}

  runApp(const MaterialApp(
    title: 'Circuito de Descobertas',
    debugShowCheckedModeBanner: false,
    home: HomePage(),
  ));
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  StreamSubscription? sub;

  @override
  void initState() {
    super.initState();
    // Atualizacao em tempo real do Remote Config
    sub = rc.onConfigUpdated.listen((_) async {
      await rc.activate();
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    sub?.cancel();
    super.dispose();
  }

  List<String> get destaques => rc
      .getString('estandes_destaque')
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  Future<void> abrirScanner() async {
    final codigo = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const ScannerPage()),
    );
    if (codigo == null) return;
    final msg = await fazerCheckin(codigo.trim());
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        content: Text(msg),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<String> fazerCheckin(String estandeId) async {
    if (estandeId.isEmpty || estandeId.contains('/')) return 'QR inválido.';
    final uid = FirebaseAuth.instance.currentUser!.uid;
    try {
      final estande = await db.collection('estandes').doc(estandeId).get();
      if (!estande.exists) return 'QR inválido: estande não encontrado.';
      if (estande.data()?['ativo'] != true) return 'Este estande está inativo.';

      // Chave composta: uma visita por visitante e por estande
      final ref = db.collection('checkins').doc('${uid}_$estandeId');
      if ((await ref.get()).exists) return 'Você já registrou visita neste estande.';

      await ref.set({
        'uid': uid,
        'estandeId': estandeId,
        'criadoEm': FieldValue.serverTimestamp(),
      });
      await analytics.logEvent(
        name: 'checkin_concluido',
        parameters: {'estande_id': estandeId},
      );
      return 'Check-in confirmado em ${estande.data()?['nome']}!';
    } catch (e) {
      return 'Erro: $e';
    }
  }

  @override
  Widget build(BuildContext context) {
    final missao = rc.getBool('missao_ativa');
    final ids = destaques;

    return Scaffold(
      appBar: AppBar(title: const Text('Circuito de Descobertas')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: abrirScanner,
        icon: const Icon(Icons.qr_code_scanner),
        label: const Text('Check-in'),
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: db.collection('estandes').where('ativo', isEqualTo: true).snapshots(),
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('Erro: ${snap.error}'));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());

          final docs = snap.data!.docs;
          final participantes = docs.where((d) => ids.contains(d.id)).toList();

          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
            children: [
              if (missao)
                Card(
                  color: Colors.amber.shade200,
                  child: ListTile(
                    leading: const Icon(Icons.flag, size: 36),
                    title: const Text('Missão surpresa!',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text('Visite os ${participantes.length} estandes em destaque'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      analytics.logEvent(name: 'missao_aberta');
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => MissaoPage(participantes)),
                      );
                    },
                  ),
                ),
              for (final d in docs) EstandeCard(d, destaque: missao && ids.contains(d.id)),
            ],
          );
        },
      ),
    );
  }
}

class EstandeCard extends StatelessWidget {
  final QueryDocumentSnapshot<Map<String, dynamic>> doc;
  final bool destaque;

  const EstandeCard(this.doc, {super.key, this.destaque = false});

  @override
  Widget build(BuildContext context) {
    final d = doc.data();
    return Card(
      color: destaque ? Colors.amber.shade50 : null,
      shape: destaque
          ? RoundedRectangleBorder(
              side: const BorderSide(color: Colors.amber, width: 2),
              borderRadius: BorderRadius.circular(12))
          : null,
      child: ListTile(
        leading: Icon(destaque ? Icons.star : Icons.storefront,
            color: destaque ? Colors.amber.shade800 : null),
        title: Text(d['nome'] ?? doc.id),
        subtitle: Text('${d['descricao'] ?? ''}\nLocal: ${d['localizacao'] ?? ''}'),
        isThreeLine: true,
      ),
    );
  }
}

class MissaoPage extends StatelessWidget {
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> estandes;

  const MissaoPage(this.estandes, {super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Missão surpresa')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const Padding(
            padding: EdgeInsets.all(8),
            child: Text('Visite estes estandes e faça o check-in pelo QR code:',
                style: TextStyle(fontSize: 16)),
          ),
          for (final d in estandes) EstandeCard(d, destaque: true),
        ],
      ),
    );
  }
}

class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key});

  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  final controller = MobileScannerController();
  bool lido = false;

  void retornar(String? valor) {
    if (lido || valor == null) return;
    lido = true;
    Navigator.pop(context, valor);
  }

  // Ler QR a partir de um print salvo na galeria
  Future<void> galeria() async {
    final img = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (img == null) return;
    final res = await controller.analyzeImage(img.path);
    final valor = res?.barcodes.firstOrNull?.rawValue;
    if (valor == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Nenhum QR encontrado na imagem.')),
        );
      }
      return;
    }
    retornar(valor);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ler QR code')),
      body: MobileScanner(
        controller: controller,
        onDetect: (cap) => retornar(cap.barcodes.firstOrNull?.rawValue),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: galeria,
        icon: const Icon(Icons.photo),
        label: const Text('Da galeria'),
      ),
    );
  }
}