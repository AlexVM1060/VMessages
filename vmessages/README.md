# vmessages

Base de mensajería Flutter (Android, iOS, macOS) con UI estilo iMessage y backend básico en Supabase.

Autenticación actual: número de teléfono + código personal (sin OTP por SMS).

## Configuración

1. Crea tus tablas en Supabase con el SQL de `supabase_schema.sql`.
2. Usa `env/dev.json` para credenciales locales (ya configurado en este proyecto).

## Ejecutar

```bash
flutter pub get
flutter run --dart-define-from-file=env/dev.json
```

Opcional por plataforma:

```bash
flutter run -d android --dart-define-from-file=env/dev.json
flutter run -d ios --dart-define-from-file=env/dev.json
flutter run -d macos --dart-define-from-file=env/dev.json
```
