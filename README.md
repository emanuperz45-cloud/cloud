# Sistema de balanceo estilo Spider-Man (PS4)

Diseño técnico e implementación de referencia de un sistema de *web swinging* en tercera persona:
física de péndulo regulado, FSM de movimiento aéreo, pipeline de animación procedural/IK e
integración con Blender. La demo añade además el planeo con **Web Wings**, túneles de viento,
corrientes ascendentes y el **Super Slingshot** de *Spider-Man 2*.

- **Documento de diseño:** [`docs/DISENO_SISTEMA_BALANCEO.md`](docs/DISENO_SISTEMA_BALANCEO.md)
- **Física, simulador y baker de Blender (Python):** [`tools/swing_lab/`](tools/swing_lab)
- **Runtime para Godot 4.3+ (GDScript):** [`godot/swing_system/`](godot/swing_system)
- **Demo jugable (proyecto Godot 4.7):** [`godot/`](godot) — ciudad procedural + personaje con cuerpo continuo y piel; exporta a `.exe`
- **Horneado del cuerpo:** [`tools/body_baker/`](tools/body_baker) — malla anatómica por SDF + marching cubes con pesos de piel

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
# .exe reducido (~28 MB en vez de 104 MB): compilar la plantilla slim y usar su preset
godot/export/build_slim_template.sh /ruta/a/godot-4.7.2-stable windows
cp /ruta/a/godot-4.7.2-stable/bin/godot.windows.template_release.x86_64.slim.exe godot/build/templates/
godot --headless --path godot --export-release "Windows Slim" build/WebSwingDemo.exe
# Pruebas automáticas sin interfaz (imprimen un resumen JSON):
godot --headless --path godot --fixed-fps 60 -- --autopilot=120 --scenario=tour
godot --headless --path godot --fixed-fps 60 -- --autopilot=26 --scenario=hang   # apuntar, clic y mantenerlo
godot --headless --path godot --fixed-fps 60 -- --autopilot=11 --scenario=aim    # la web va donde apunta la mira
godot --headless --path godot --fixed-fps 60 -- --autopilot=23 --scenario=moves  # moveset completo
godot --headless --path godot --fixed-fps 60 -- --autopilot=20 --scenario=glide  # Web Wings y viento
godot --headless --path godot --fixed-fps 60 -- --autopilot=14 --scenario=sling  # Slingshot y loop
godot --headless --path godot --fixed-fps 60 -- --autopilot=4 --scenario=run     # sprint con curva
godot --headless --path godot --fixed-fps 60 -- --autopilot=14 --scenario=sm2    # loop, dash, jump, vault, borde
# Regenerar el cuerpo con piel (numpy + scikit-image):
python3 tools/body_baker/bake_body.py
# Hoja de fotogramas de una animación (sin la ciudad; casos en docs, apéndice C.2):
xvfb-run godot --path godot --rendering-driver opengl3 --fixed-fps 60 --resolution 560x640 \
    --script res://demo/anim_lab.gd -- --case=sprint --view=side --out=sprint.png
```

Controles (moveset del original, ver §2.0 del documento). En el juego están siempre a la
vista en una franja compacta abajo a la izquierda (H la oculta o la vuelve a mostrar):

| Acción | Teclado y ratón | Mando |
|---|---|---|
| Balanceo: la telaraña se lanza **donde apunta la mira** (centro de la pantalla; el marcador cian enseña el punto). **Mantener = misma telaraña** (se amortigua hasta quedar colgado, nunca salta a otro edificio); soltar = soltarse; otra telaraña = otro clic | Clic izquierdo | RT / R2 |
| Colgado: subir / bajar por la telaraña | W / S | Stick izq. |
| Salto: en el swing (abajo = adelante, final = arriba), Web Zip en el aire (Quick Zip si repites), Charge Jump manteniendo en el suelo, Quick Recovery al rodar, Point Launch al llegar a un perch, tirón hacia arriba o salto en una pared | Espacio | A |
| Sprint (suelo) / correr por la pared (sin clic se trepa) | Clic izq. mantenido | RT / R2 |
| Picada / girar una esquina corriendo por la pared | Mayús | B |
| Point zip al punto amarillo | Q o clic derecho | LT / L2 |
| Trucos según dirección (recargan el medidor); mantenido en un balanceo rápido = cierra el arco | F + WASD | LB + stick |
| **Loop de Loop** (*SM2*): picada y balanceo; al completar la vuelta sale disparado | Mayús + clic | B + RT |
| **Spider-Dash** / **Spider-Jump** (*SM2*): gastan una carga del medidor (barras abajo) | C / V | R3 / L3 |
| Parkour: esprintando salta solo los bordes de azotea y pasa por encima de obstáculos bajos | Clic + W | RT + stick |
| **Web Wings** en el aire (otra vez = plegar): W picar, S frenar/subir, A/D girar (~97°/s); o gira la cámara con el ratón y vuela hacia donde miras; abrirlas en picada = impulso | G, Ctrl o rueda | Y |
| **Super Slingshot**: mantener point zip y salto, soltar salto para lanzar (soltar point zip cancela) | Q + Espacio | LT + A |
| Reaparecer / ayuda | R / H | Back / Start |

En la ciudad hay **túneles de viento** (anillos azules sobre 5 avenidas) que llevan a ~205 km/h a
quien entra planeando y **corrientes ascendentes** (columnas sobre rejillas en azoteas) que elevan.

`tools/swing_lab/swing_core.py` es la fuente de verdad de la física; `godot/swing_system/regulated_pendulum.gd`
es un port 1:1. Si cambias un parámetro, cámbialo en ambos (`SwingTuning`) y vuelve a correr el simulador.
