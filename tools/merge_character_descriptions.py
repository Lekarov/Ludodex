"""Construit un CSV d'import complet sans accès réseau ni secret."""

import csv
import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 4:
        print("Usage: merge_character_descriptions.py INPUT.csv DESCRIPTIONS.json OUTPUT.csv")
        return 2

    source, descriptions_path, target = map(Path, sys.argv[1:])
    with descriptions_path.open(encoding="utf-8-sig") as handle:
        descriptions = json.load(handle)

    with source.open(encoding="utf-8-sig", newline="") as input_handle:
        reader = csv.DictReader(input_handle)
        if not reader.fieldnames or "character_id" not in reader.fieldnames:
            raise RuntimeError("Colonne character_id absente du catalogue de personnages.")
        fieldnames = [*reader.fieldnames, "description_fr"]
        count = 0
        missing = 0
        with target.open("w", encoding="utf-8", newline="") as output_handle:
            writer = csv.DictWriter(output_handle, fieldnames=fieldnames)
            writer.writeheader()
            for row in reader:
                description = descriptions.get(row["character_id"], "")
                if not description:
                    missing += 1
                row["description_fr"] = description
                writer.writerow(row)
                count += 1

    if missing:
        raise RuntimeError(f"{missing} descriptions manquent sur {count} personnages.")
    print(f"CSV complet généré : {count} personnages, 0 description manquante.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

