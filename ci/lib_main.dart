import 'dart:convert';
import 'dart:io';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:geojson_vi/geojson_vi.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart' as xml;
import 'package:archive/archive_io.dart';
import 'package:gpx/gpx.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FMTCObjectBoxBackend().initialise();
  runApp(const TerritoriesApp());
}

class TerritoriesApp extends StatelessWidget {
  const TerritoriesApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Territórios Urbanos',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue),
      home: const MapHomePage(),
    );
  }
}

class Territory {
  String id;
  String name;
  int colorValue; // ARGB
  List<LatLng> points;

  Territory({
    required this.id,
    required this.name,
    required this.colorValue,
    required this.points,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'color': colorValue,
        'points': points.map((p) => {'lat': p.latitude, 'lng': p.longitude}).toList(),
      };

  factory Territory.fromJson(Map<String, dynamic> j) => Territory(
        id: j['id'],
        name: j['name'],
        colorValue: j['color'],
        points: (j['points'] as List)
            .map((p) => LatLng((p['lat'] as num).toDouble(), (p['lng'] as num).toDouble()))
            .toList(),
      );

  GeoJSONFeature toGeoJSON() {
    final coords = points.map((p) => [p.longitude, p.latitude]).toList();
    return GeoJSONFeature(
      geometry: GeoJSONPolygon(coordinates: [coords]),
      properties: {'id': id, 'name': name, 'color': colorValue},
    );
  }

  static Territory fromGeoJSON(GeoJSONFeature f) {
    final poly = f.geometry as GeoJSONPolygon;
    final ring = poly.coordinates.first;
    return Territory(
      id: (f.properties?['id']?.toString() ?? const Uuid().v4()),
      name: (f.properties?['name']?.toString() ?? 'Sem nome'),
      colorValue: int.tryParse(f.properties?['color']?.toString() ?? '') ??
          const Color(0xFF1E88E5).value,
      points: ring.map((c) => LatLng(c[1].toDouble(), c[0].toDouble())).toList(),
    );
  }
}

class MapHomePage extends StatefulWidget {
  const MapHomePage({super.key});
  @override
  State<MapHomePage> createState() => _MapHomePageState();
}

enum EditMode { none, drawing, editing }

class _MapHomePageState extends State<MapHomePage> {
  final uuid = const Uuid();

  List<Territory> territories = [];
  String? selectedId;
  EditMode mode = EditMode.none;
  List<LatLng> draft = [];

  final mapController = MapController();
  double zoom = 13;
  LatLng center = LatLng(-2.5589, -44.0609); // MA por padrão

  late final FMTCStore store;

  @override
  void initState() {
    super.initState();
    store = FMTCStore('defaultStore')..manage.create();
    _loadTerritories();
  }

  Future<void> _loadTerritories() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('territories');
    if (raw != null) {
      final list = (jsonDecode(raw) as List)
          .map((e) => Territory.fromJson(e as Map<String, dynamic>))
          .toList();
      setState(() => territories = list);
    }
  }

  Future<void> _saveTerritories() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'territories',
      jsonEncode(territories.map((t) => t.toJson()).toList()),
    );
  }

  // ===== BUSCA DE CIDADE (Nominatim) =====
  Future<void> _searchCity(String q) async {
    if (q.trim().isEmpty) return;
    final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/search?format=json&q=${Uri.encodeComponent(q)}');
    final r = await http.get(uri, headers: {'User-Agent': 'territorios_urbanos/1.0'});
    if (r.statusCode == 200) {
      final list = jsonDecode(r.body) as List;
      if (list.isNotEmpty) {
        final lat = double.parse(list[0]['lat']);
        final lon = double.parse(list[0]['lon']);
        setState(() {
          center = LatLng(lat, lon);
          zoom = 12;
        });
        mapController.move(center, zoom);
      }
    }
  }

  // ===== DESENHO/EDIÇÃO =====
  void _startDrawing() {
    setState(() {
      mode = EditMode.drawing;
      draft = [];
      selectedId = null;
    });
  }

  void _cancelDraft() {
    setState(() {
      mode = EditMode.none;
      draft = [];
    });
  }

  Future<void> _finishDraft() async {
    if (draft.length < 3) {
      _toast('Mínimo de 3 pontos.');
      return;
    }
    final meta = await showDialog<_TerritoryMeta>(
      context: context,
      builder: (_) => const TerritoryMetaDialog(),
    );
    if (meta == null) return;
    setState(() {
      territories.add(Territory(
        id: uuid.v4(),
        name: meta.name,
        colorValue: meta.color.value,
        points: List.from(draft),
      ));
      mode = EditMode.none;
      draft = [];
    });
    _saveTerritories();
  }

  void _selectForEdit(String id) {
    final t = territories.firstWhereOrNull((e) => e.id == id);
    if (t == null) return;
    setState(() {
      selectedId = id;
      mode = EditMode.editing;
      draft = List.from(t.points);
    });
  }

  void _applyEdit() {
    if (selectedId == null || draft.length < 3) return;
    setState(() {
      final idx = territories.indexWhere((e) => e.id == selectedId);
      territories[idx] = Territory(
        id: territories[idx].id,
        name: territories[idx].name,
        colorValue: territories[idx].colorValue,
        points: List.from(draft),
      );
      mode = EditMode.none;
      selectedId = null;
      draft = [];
    });
    _saveTerritories();
  }

  void _deleteSelected() {
    if (selectedId == null) return;
    setState(() {
      territories.removeWhere((t) => t.id == selectedId);
      mode = EditMode.none;
      selectedId = null;
      draft = [];
    });
    _saveTerritories();
  }

  void _toast(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  // ===== GEO: HELPERS =====
  String _toKmlColor(int argb) {
    final a = (argb >> 24) & 0xFF;
    final r = (argb >> 16) & 0xFF;
    final g = (argb >> 8) & 0xFF;
    final b = (argb) & 0xFF;
    String hh(int v) => v.toRadixString(16).padLeft(2, '0');
    // KML usa AABBGGRR
    return '${hh(a)}${hh(b)}${hh(g)}${hh(r)}';
  }

  // ===== IMPORT/EXPORT =====
  Future<void> _exportGeoJSON() async {
    final fc = GeoJSONFeatureCollection(
      features: territories.map((t) => t.toGeoJSON()).toList(),
    );
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/territories.geojson');
    await file.writeAsString(fc.toJSON());
    _toast('GeoJSON exportado: ${file.path}');
  }

  Future<void> _importGeoJSON() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['geojson', 'json'],
    );
    if (res == null || res.files.isEmpty) return;
    final path = res.files.single.path;
    if (path == null) return;

    final text = await File(path).readAsString();
    final parsed = GeoJSONFeatureCollection.fromJSON(text);

    // Em algumas versões, features pode ser List<dynamic> ou List<GeoJSONFeature?>
    final feats = parsed.features.whereType<GeoJSONFeature>().toList();
    final list = feats.map(Territory.fromGeoJSON).toList();

    setState(() {
      territories.addAll(list);
    });
    await _saveTerritories();
    _toast('GeoJSON importado: +${list.length} territórios');
  }

  Future<void> _exportKML() async {
    final builder = xml.XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="UTF-8"');
    builder.element('kml', namespaces: {'': 'http://www.opengis.net/kml/2.2'}, nest: () {
      builder.element('Document', nest: () {
        for (final t in territories) {
          builder.element('Style', attributes: {'id': 's_${t.id}'}, nest: () {
            builder.element('LineStyle', nest: () {
              builder.element('color', nest: _toKmlColor(t.colorValue));
              builder.element('width', nest: '2');
            });
            builder.element('PolyStyle', nest: () {
              final base = t.colorValue | 0x55000000;
              builder.element('color', nest: _toKmlColor(base));
              builder.element('fill', nest: '1');
              builder.element('outline', nest: '1');
            });
          });
        }
        for (final t in territories) {
          builder.element('Placemark', nest: () {
            builder.element('name', nest: t.name);
            builder.element('styleUrl', nest: '#s_${t.id}');
            builder.element('Polygon', nest: () {
              builder.element('outerBoundaryIs', nest: () {
                builder.element('LinearRing', nest: () {
                  final coords = List<LatLng>.from(t.points);
                  if (coords.isNotEmpty && coords.first != coords.last) {
                    coords.add(coords.first);
                  }
                  final coordStr =
                      coords.map((p) => '${p.longitude},${p.latitude},0').join(' ');
                  builder.element('coordinates', nest: coordStr);
                });
              });
            });
          });
        }
      });
    });
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/territories.kml');
    await file.writeAsString(builder.buildDocument().toXmlString(pretty: true));
    _toast('KML exportado: ${file.path}');
  }

  Future<void> _exportKMZ() async {
    final dir = await getApplicationDocumentsDirectory();
    final kmlPath = '${dir.path}/territories.kml';
    await _exportKML();
    final encoder = ZipFileEncoder();
    final kmzPath = '${dir.path}/territories.kmz';
    encoder.create(kmzPath);
    encoder.addFile(File(kmlPath));
    encoder.close();
    _toast('KMZ exportado: $kmzPath');
  }

  Future<void> _exportWKT() async {
    final sb = StringBuffer();
    for (final t in territories) {
      final coords = List<LatLng>.from(t.points);
      if (coords.isNotEmpty && coords.first != coords.last) {
        coords.add(coords.first);
      }
      final wkt =
          'POLYGON((${coords.map((p) => '${p.longitude} ${p.latitude}').join(', ')}))';
      sb.writeln('-- ${t.name}');
      sb.writeln(wkt);
      sb.writeln();
    }
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/territories.wkt');
    await file.writeAsString(sb.toString());
    _toast('WKT exportado: ${file.path}');
  }

  Future<void> _exportGPX() async {
    final gpx = Gpx();
    for (final t in territories) {
      final trk = Trk(name: t.name);
      final seg = Trkseg();
      final pts = List<LatLng>.from(t.points);
      if (pts.isNotEmpty && pts.first != pts.last) {
        pts.add(pts.first);
      }
      for (final p in pts) {
        seg.trkpts.add(Wpt(lat: p.latitude, lon: p.longitude));
      }
      trk.trksegs.add(seg);
      gpx.trks.add(trk);
    }
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/territories.gpx');
    await file.writeAsString(GpxWriter().asString(gpx, pretty: true));
    _toast('GPX exportado: ${file.path}');
  }

  // ===== OFFLINE (cache tiles OSM) =====
  Future<void> _seedTilesForView() async {
    // Temporário: API do FMTC v10 mudou; vamos reativar depois com Seeder/Jobs.
    _toast('Baixar mapa offline desta área: em breve (atualizando API).');
  }

  @override
  Widget build(BuildContext context) {
    final leftActions = <Widget>[
      PopupMenuButton<String>(
        tooltip: 'Importar/Exportar',
        onSelected: (v) {
          switch (v) {
            case 'import_geojson':
              _importGeoJSON();
              break;
            case 'export_geojson':
              _exportGeoJSON();
              break;
            case 'export_kml':
              _exportKML();
              break;
            case 'export_kmz':
              _exportKMZ();
              break;
            case 'export_wkt':
              _exportWKT();
              break;
            case 'export_gpx':
              _exportGPX();
              break;
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'import_geojson', child: Text('Importar GeoJSON…')),
          PopupMenuDivider(),
          PopupMenuItem(value: 'export_geojson', child: Text('Exportar GeoJSON')),
          PopupMenuItem(value: 'export_kml', child: Text('Exportar KML')),
          PopupMenuItem(value: 'export_kmz', child: Text('Exportar KMZ (compactado)')),
          PopupMenuItem(value: 'export_wkt', child: Text('Exportar WKT')),
          PopupMenuItem(value: 'export_gpx', child: Text('Exportar GPX')),
        ],
      ),
      PopupMenuButton<String>(
        tooltip: 'Mapa Offline',
        onSelected: (v) {
          if (v == 'seed') _seedTilesForView();
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'seed', child: Text('Baixar mapa desta área (offline)')),
        ],
      ),
    ];

    final search = SizedBox(width: 320, child: _SearchBox(onSearch: _searchCity));

    return Scaffold(
      appBar: AppBar(title: const Text('Territórios Urbanos'), actions: [...leftActions, search]),
      body: Stack(children: [
        FlutterMap(
          mapController: mapController,
          options: MapOptions(
            initialCenter: center,
            initialZoom: zoom,
            onTap: (tapPos, latlng) {
              if (mode == EditMode.drawing) {
                setState(() => draft.add(latlng));
              }
            },
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
              subdomains: const ['a', 'b', 'c'],
              userAgentPackageName: 'com.example.territorios_urbanos',
              tileProvider: store.getTileProvider(),
            ),
            PolygonLayer(polygons: [
              ...territories.map((t) => Polygon(
                    points: t.points,
                    color: Color(t.colorValue).withOpacity(0.25),
                    borderColor: Color(t.colorValue),
                    borderStrokeWidth: 2,
                  )),
              if (draft.isNotEmpty)
                Polygon(
                  points: draft,
                  color: Colors.orange.withOpacity(0.2),
                  borderColor: Colors.orange,
                  borderStrokeWidth: 2,
                ),
            ]),
            MarkerLayer(markers: [
              ...territories.map((t) => Marker(
                    point: _centroid(t.points),
                    width: 190,
                    height: 48,
                    child: _TerritoryChip(
                      name: t.name,
                      color: Color(t.colorValue),
                      onDelete: () {
                        setState(() => territories.removeWhere((e) => e.id == t.id));
                        _saveTerritories();
                      },
                      onZoomTo: () {
                        mapController.move(_centroid(t.points), 16);
                      },
                      onEdit: () => _selectForEdit(t.id),
                    ),
                  )),
              if (mode == EditMode.editing)
                ...List.generate(
                  draft.length,
                  (i) => Marker(
                    point: draft[i],
                    width: 24,
                    height: 24,
                    child: _DragHandle(
                      onDragEnd: (newLatLng) {
                        setState(() => draft[i] = newLatLng);
                      },
                    ),
                  ),
                ),
            ]),
          ],
        ),
        Positioned(
          bottom: 12,
          left: 12,
          right: 12,
          child: _Controls(
            mode: mode,
            onStart: _startDrawing,
            onCancel: _cancelDraft,
            onFinish: _finishDraft,
            onApplyEdit: _applyEdit,
            onDeleteSelected: _deleteSelected,
            onRecenter: () {
              mapController.move(center, zoom);
            },
          ),
        ),
      ]),
    );
  }

  LatLng _centroid(List<LatLng> pts) {
    double x = 0, y = 0;
    for (final p in pts) {
      x += p.latitude;
      y += p.longitude;
    }
    return LatLng(x / pts.length, y / pts.length);
  }
}

class _Controls extends StatelessWidget {
  final EditMode mode;
  final VoidCallback onStart, onCancel, onFinish, onApplyEdit, onDeleteSelected, onRecenter;
  const _Controls({
    super.key,
    required this.mode,
    required this.onStart,
    required this.onCancel,
    required this.onFinish,
    required this.onApplyEdit,
    required this.onDeleteSelected,
    required this.onRecenter,
  });
  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            FilledButton.tonal(onPressed: onRecenter, child: const Text('Centralizar')),
            if (mode == EditMode.none) FilledButton(onPressed: onStart, child: const Text('Desenhar')),
            if (mode == EditMode.drawing) ...[
              OutlinedButton(onPressed: onCancel, child: const Text('Cancelar')),
              FilledButton(onPressed: onFinish, child: const Text('Concluir')),
            ],
            if (mode == EditMode.editing) ...[
              OutlinedButton(onPressed: onCancel, child: const Text('Cancelar')),
              FilledButton.tonal(onPressed: onApplyEdit, child: const Text('Aplicar edição')),
              FilledButton(onPressed: onDeleteSelected, child: const Text('Excluir')),
            ],
          ],
        ),
      ),
    );
  }
}

class _TerritoryChip extends StatelessWidget {
  final String name;
  final Color color;
  final VoidCallback onDelete;
  final VoidCallback onZoomTo;
  final VoidCallback onEdit;
  const _TerritoryChip({
    super.key,
    required this.name,
    required this.color,
    required this.onDelete,
    required this.onZoomTo,
    required this.onEdit,
  });
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onZoomTo,
      onLongPress: onEdit,
      child: Chip(
        avatar: CircleAvatar(backgroundColor: color),
        label: Text(name, overflow: TextOverflow.ellipsis),
        deleteIcon: const Icon(Icons.delete_outline),
        onDeleted: onDelete,
      ),
    );
  }
}

class _DragHandle extends StatelessWidget {
  final ValueChanged<LatLng> onDragEnd;
  const _DragHandle({super.key, required this.onDragEnd});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () async {
        final result =
            await showDialog<LatLng>(context: context, builder: (_) => const _LatLngEditDialog());
        if (result != null) onDragEnd(result);
      },
      child: const Icon(Icons.circle, size: 18, color: Colors.orange),
    );
  }
}

class _LatLngEditDialog extends StatefulWidget {
  const _LatLngEditDialog();
  @override
  State<_LatLngEditDialog> createState() => _LatLngEditDialogState();
}

class _LatLngEditDialogState extends State<_LatLngEditDialog> {
  final lat = TextEditingController();
  final lon = TextEditingController();
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Mover vértice'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(controller: lat, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Latitude')),
          TextField(controller: lon, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Longitude')),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(
          onPressed: () {
            final la = double.tryParse(lat.text);
            final lo = double.tryParse(lon.text);
            if (la == null || lo == null) return;
            Navigator.pop(context, LatLng(la, lo));
          },
          child: const Text('Aplicar'),
        )
      ],
    );
  }
}

class _TerritoryMeta {
  final String name;
  final Color color;
  const _TerritoryMeta(this.name, this.color);
}

class TerritoryMetaDialog extends StatefulWidget {
  const TerritoryMetaDialog({super.key});
  @override
  State<TerritoryMetaDialog> createState() => _TerritoryMetaDialogState();
}

class _TerritoryMetaDialogState extends State<TerritoryMetaDialog> {
  final TextEditingController nameCtrl = TextEditingController();
  Color currentColor = const Color(0xFF1E88E5);
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Novo território'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Nome')),
            const SizedBox(height: 16),
            const Text('Cor'),
            const SizedBox(height: 8),
            BlockPicker(pickerColor: currentColor, onColorChanged: (c) => setState(() => currentColor = c))
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(
          onPressed: () {
            if (nameCtrl.text.trim().isEmpty) return;
            Navigator.pop(context, _TerritoryMeta(nameCtrl.text.trim(), currentColor));
          },
          child: const Text('Salvar'),
        ),
      ],
    );
  }
}

class _SearchBox extends StatefulWidget {
  final ValueChanged<String> onSearch;
  const _SearchBox({super.key, required this.onSearch});
  @override
  State<_SearchBox> createState() => _SearchBoxState();
}

class _SearchBoxState extends State<_SearchBox> {
  final ctrl = TextEditingController();
  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: ctrl,
      decoration: const InputDecoration(
        prefixIcon: Icon(Icons.search),
        hintText: 'Buscar cidade/bairro (ex: São Luís, MA)',
      ),
      onSubmitted: widget.onSearch,
      textInputAction: TextInputAction.search,
    );
  }
}
