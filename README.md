# Sistema de balanceo estilo Spider-Man (PS4)

Diseño técnico e implementación de referencia de un sistema de *web swinging* en tercera persona:
física de péndulo regulado, FSM de movimiento aéreo, pipeline de animación procedural/IK e
integración con Blender.

- **Documento de diseño:** [`docs/DISENO_SISTEMA_BALANCEO.md`](docs/DISENO_SISTEMA_BALANCEO.md)
- **Física, simulador y baker de Blender (Python):** [`tools/swing_lab/`](tools/swing_lab)
- **Runtime para Godot 4.3+ (GDScript):** [`godot/swing_system/`](godot/swing_system)
- **Demo jugable (proyecto Godot 4.7):** [`godot/`](godot) — ciudad procedural + personaje; exporta a `.exe`

## Uso rápido

```bash
# Tests de física (sin dependencias)
python3 -m unittest discover -s tools/swing_lab -p "test_*.py"

# Simulador de calibración: métricas de la sección 5 del documento
python3 tools/swing_lab/city_sim.py

# Test end-to-end del baker de Blender (requiere bpy)
pip install bpy==5.0.1 && python3 -m unittest discover -s tools/swing_lab -p "test_blender*.py"

# Hornear un arco sobre tu rig y exportarlo
blender -b rig.blend --python tools/swing_lab/blender_arc_baker.py -- \
    --armature Spidey --side R --action Swing_R --curve-bones --glb out/swing_R.glb
```

## Demo jugable

```bash
# Jugar desde el editor: abrir la carpeta godot/ en Godot 4.7 y pulsar F5.
# Exportar el .exe de Windows (requiere las plantillas de exportación 4.7.2):
godot --headless --path godot --export-release "Windows Desktop" build/WebSwingDemo.exe
# Prueba automática sin interfaz (autopiloto 120 s, imprime un resumen):
godot --headless --path godot --fixed-fps 60 -- --autopilot=120
```

Controles: mantener clic izquierdo / R2 para balancearse, Espacio / A salto, Mayús / B picada,
E / X web zip, Q / L2 point zip, F / Y truco, WASD + ratón (o sticks), R reaparecer.

`tools/swing_lab/swing_core.py` es la fuente de verdad de la física; `godot/swing_system/regulated_pendulum.gd`
es un port 1:1. Si cambias un parámetro, cámbialo en ambos (`SwingTuning`) y vuelve a correr el simulador.
