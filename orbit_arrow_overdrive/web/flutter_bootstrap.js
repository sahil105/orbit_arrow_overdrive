{{flutter_js}}
{{flutter_build_config}}
// Serve the compiled engine from this deployment rather than an external CDN.
for (const build of _flutter.buildConfig.builds) {
  if (build.mainJsPath) build.mainJsPath += '?v=1.4.1';
}
_flutter.loader.load({config: {canvasKitBaseUrl: 'canvaskit/'}});
