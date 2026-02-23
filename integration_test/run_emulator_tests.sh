#!/bin/bash
set -euo pipefail

# Wait for package manager to be ready
echo "⏳ Waiting for package manager..."
for i in $(seq 1 30); do
  if adb shell pm list packages >/dev/null 2>&1; then
    echo "✅ Package manager ready after ${i}s"
    break
  fi
  sleep 2
done

# Install the debug APK (with retry)
echo "📦 Installing APK..."
for attempt in 1 2 3; do
  if adb install build/app/outputs/flutter-apk/app-debug.apk; then
    echo "✅ APK installed on attempt $attempt"
    break
  fi
  echo "⚠️ Install failed (attempt $attempt/3), retrying in 10s..."
  sleep 10
  if [ $attempt -eq 3 ]; then
    echo "❌ APK install failed after 3 attempts"
    exit 1
  fi
done

# Launch the app
adb shell am start -n com.clawd.sshproxy/com.clawd.sshproxy.MainActivity

# Set up port forwarding (emulator localhost:7070 → host localhost:7070)
adb forward tcp:7070 tcp:7070

# Wait for API to be ready (up to 60s)
echo "⏳ Waiting for API server..."
for i in $(seq 1 60); do
  if curl -sf http://127.0.0.1:7070/ping >/dev/null 2>&1; then
    echo "✅ API ready after ${i}s"
    break
  fi
  if [ $i -eq 60 ]; then
    echo "❌ API not ready after 60s"
    adb logcat -d | grep -i "api\|server\|7070" | tail -30
    exit 1
  fi
  sleep 1
done

# Run the integration tests
chmod +x integration_test/api_test.sh
bash integration_test/api_test.sh
