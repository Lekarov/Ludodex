#!/usr/bin/env python3
"""Traduit hors ligne les summaries avec Argos Translate, avec reprise exacte.

Installation/modèles (une seule fois, réseau requis) :
  py -m pip install argostranslate
  python outils_igdb/translate_descriptions.py --install-models --langs fr
Traduction ensuite hors ligne :
  python outils_igdb/translate_descriptions.py
Options espagnol/allemand : --langs fr,es,de (fr seul par défaut).
"""
import argparse, json, os, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
INPUT = ROOT / "data/volumes/descriptions_en_2026/descriptions_en_2026.json"
LANGS = {"fr": "français", "es": "espagnol", "de": "allemand"}

def paths(lang):
    folder = ROOT / f"data/volumes/descriptions_{lang}_2026"
    return (folder / f"descriptions_{lang}_2026.json",
            folder / f"descriptions_{lang}_2026.checkpoint.jsonl",
            folder / f"RAPPORT_DESCRIPTIONS_{lang.upper()}_2026.md")

def load(path):
    if not path.exists(): return {}
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict): raise RuntimeError(f"Objet JSON attendu : {path}")
    return value

def atomic(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(tmp, path)

def parse_langs(raw):
    result = list(dict.fromkeys(x.strip().lower() for x in raw.split(",") if x.strip()))
    if not result or any(x not in LANGS for x in result):
        raise argparse.ArgumentTypeError("langues acceptées : fr,es,de")
    return result

def argos_modules():
    try:
        import argostranslate.package as package
        import argostranslate.translate as translate
        return package, translate
    except ImportError as exc:
        raise RuntimeError("Installer Argos : py -m pip install argostranslate") from exc

def translator_for(module, target):
    installed = {lang.code: lang for lang in module.get_installed_languages()}
    if "en" not in installed or target not in installed: return None
    try: return installed["en"].get_translation(installed[target])
    except Exception: return None

def install_models(package, translate, langs):
    missing = [lang for lang in langs if translator_for(translate, lang) is None]
    if not missing: print("Modèles déjà installés."); return
    print("Téléchargement de l'index Argos (réseau requis)...")
    package.update_package_index(); available = package.get_available_packages()
    for lang in missing:
        model = next((x for x in available if x.from_code == "en" and x.to_code == lang), None)
        if model is None: raise RuntimeError(f"Modèle direct en -> {lang} introuvable")
        print(f"Installation en -> {lang}...")
        package.install_from_path(model.download())

def resume(output, checkpoint):
    result = load(output)
    if checkpoint.exists():
        lines = checkpoint.read_text(encoding="utf-8").splitlines()
        for number, line in enumerate(lines, 1):
            if not line.strip(): continue
            try: key, value = json.loads(line)
            except (json.JSONDecodeError, TypeError, ValueError):
                if number != len(lines): raise RuntimeError(f"Checkpoint corrompu ligne {number}: {checkpoint}")
                break  # dernière ligne éventuellement tronquée par une coupure brutale
            result[key] = value
    return result

def fmt(seconds):
    if seconds is None: return "calcul en cours"
    hours, rest = divmod(max(0, int(seconds)), 3600); minutes, seconds = divmod(rest, 60)
    return f"{hours} h {minutes:02d} min {seconds:02d} s"

def report(path, lang, total, done, elapsed, complete):
    lines = [f"# Rapport — descriptions {LANGS[lang]}es 2026", "",
        f"Statut : **{'TERMINÉ' if complete else 'PARTIEL — reprise possible'}**", "",
        f"- Résumés anglais : **{total:,}**".replace(",", " "),
        f"- Traduits : **{done:,}**".replace(",", " "), f"- Durée : **{fmt(elapsed)}**", "",
        "Traduction automatique : relire l'argot, l'humour, les jeux de mots et les noms propres."]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")

def run_language(lang, source, translator):
    output, checkpoint, report_file = paths(lang); output.parent.mkdir(parents=True, exist_ok=True)
    result = resume(output, checkpoint); remaining = [(k, v) for k, v in source.items() if k not in result]
    started = time.monotonic(); initial = len(result)
    print(f"[{lang}] reprise {initial}, reste {len(remaining)}")
    try:
        # Une ligne validée par texte : aucune traduction achevée n'est perdue à la reprise.
        with checkpoint.open("a", encoding="utf-8", buffering=1) as journal:
            for pos, (key, text) in enumerate(remaining, 1):
                translated = translator.translate(text); result[key] = translated
                journal.write(json.dumps([key, translated], ensure_ascii=False) + "\n"); journal.flush()
                if pos == 1 or pos % 25 == 0 or pos == len(remaining):
                    elapsed = time.monotonic() - started; rate = pos / elapsed if elapsed else 0
                    eta = (len(remaining) - pos) / rate if rate else None; done = initial + pos
                    print(f"[{lang}] {done}/{len(source)} ({100*done/len(source):.1f} %), "
                          f"{rate:.2f} texte/s, reste estimé {fmt(eta)}")
                if pos % 500 == 0: atomic(output, {k: result[k] for k in source if k in result})
        ordered = {k: result[k] for k in source if k in result}; atomic(output, ordered)
        checkpoint.write_text("", encoding="utf-8")
        report(report_file, lang, len(source), len(ordered), time.monotonic()-started, True)
        print(f"[{lang}] terminé : {output}")
    except BaseException:
        report(report_file, lang, len(source), len(result), time.monotonic()-started, False); raise

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--langs", type=parse_langs, default=parse_langs("fr"))
    parser.add_argument("--install-models", action="store_true",
        help="télécharge/installe les modèles manquants; réseau requis une fois")
    args = parser.parse_args()
    try:
        package, translate = argos_modules()
        if args.install_models: install_models(package, translate, args.langs)
        translators = {}
        for lang in args.langs:
            translators[lang] = translator_for(translate, lang)
            if translators[lang] is None:
                raise RuntimeError(f"Modèle en -> {lang} absent. Lancer avec --install-models --langs {lang}")
        source = load(INPUT)
        if not source: raise RuntimeError(f"Aucun résumé dans {INPUT}; lancer d'abord fetch_descriptions.py")
        for lang in args.langs: run_language(lang, source, translators[lang])
        return 0
    except KeyboardInterrupt: print("Interruption; reprise exacte disponible.", file=sys.stderr)
    except Exception as exc: print(f"BLOCAGE : {exc}", file=sys.stderr)
    return 2

if __name__ == "__main__": raise SystemExit(main())
