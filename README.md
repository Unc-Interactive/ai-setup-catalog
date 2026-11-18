# AI Setup: model list

The list of free local models the **AI Setup** app offers, and its latest version number. The app reads these two files at most once a day; nothing else is fetched and nothing about the PC is sent.

- `catalog.json`: the models (Ollama names, sizes, licenses, memory layouts). Built by `build_catalog.py` from registry.ollama.ai. Only free licenses; the app rejects the file if any entry looks wrong.
- `app.json`: the latest app version and where to get it.
