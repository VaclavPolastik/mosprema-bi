# Power BI — jak z toho postavit report

Tenhle soubor je návod, ne teorie. Data i míry jsou hotové; zbývá je
poskládat v Power BI Desktopu. Počítej s dvěma až třemi hodinami napoprvé.

**Proč tu není hotový `.pbix`:** formát je binární a Power BI Desktop na tomhle
počítači není nainstalovaný, takže ho nemám jak vyrobit ani ověřit. Podstatné
ale je něco jiného — u pohovoru se tě nikdo nezeptá na hotový soubor, zeptá se
na model a na DAX. To si postavíš tady.

Ke stažení: [Power BI Desktop](https://www.microsoft.com/store/productId/9NTXR16HNW1T)
(Microsoft Store, zdarma, jen Windows).

---

## 1. Načtení dat (20 minut)

1. **Prázdný report** → *Získat data* → *Prázdný dotaz*.
2. *Domů* → *Správce parametrů* → **Nový parametr**:
   - Název: `SlozkaDat`
   - Typ: Text
   - Aktuální hodnota: `C:\Users\PC\Desktop\pohovor\mosprema-bi\out`
3. Pro každý blok v [`power_query.m`](power_query.m): *Nový zdroj* →
   *Prázdný dotaz* → *Rozšířený editor* → vlož kód → dotaz pojmenuj podle
   nadpisu bloku (`dim_date`, `fact_daily`, …).
   Začni funkcí `fnNacti`, ostatní dotazy ji používají.
4. *Zavřít a použít*.

> **Na co si dát pozor.** Každý převod typu má v M připsané `"en-US"`.
> CSV má desetinnou tečku, český Windows čeká čárku. Bez uvedené kultury se
> `6.09 °C` načte jako chyba nebo jako 609. Je to nejčastější důvod, proč
> „stejné CSV" jednomu funguje a druhému ne — a dobrá odpověď na otázku,
> co dělá Power Query jinak než `pd.read_csv`.

---

## 2. Model (25 minut)

### Vztahy

V zobrazení *Model* natáhni tyhle vazby. Všechny jsou **1 : N**
s jednosměrným filtrováním (dimenze filtruje fakt, ne naopak):

| Z dimenze | Sloupec | Na fakt |
|---|---|---|
| `dim_date` | `date_key` | `fact_reading`, `fact_daily`, `fact_development`, `fact_gap` |
| `dim_sensor` | `sensor_key` | `fact_reading` |
| `dim_quality` | `quality_key` | `fact_reading` |
| `dim_species` | `species_key` | `fact_development` |
| `dim_model` | `model_key` | `fact_development` |
| `dim_station` | `station_id` | všechny čtyři fakty |

Obousměrné filtrování nikde nezapínej. Model je čistá hvězda, žádná smyčka
v něm není a obousměrná vazba by jen zpomalila a zanesla nejednoznačnost.

### Tabulka kalendáře

Označ `dim_date` → *Nástroje tabulky* → **Označit jako tabulku kalendářních dat**
→ sloupec `date`.

Bez tohohle kroku nefungují časové funkce (`DATESINPERIOD`,
`SAMEPERIODLASTYEAR`) spolehlivě. Zároveň vypni automatické datum
a čas: *Soubor → Možnosti → Načtení dat → Automatické datum a čas* — jinak
si Power BI ke každému sloupci s datem vyrobí vlastní skrytý kalendář
a model nabobtná.

### Řazení podle sloupce

| Tabulka | Sloupec | Seřadit podle |
|---|---|---|
| `dim_date` | `month_name` | `month_sort` |
| `dim_date` | `weekday_name` | `weekday_sort` |
| `fact_development` | `stage` | `stage_sort` |

Bez toho se měsíce v ose seřadí abecedně: březen, červen, červenec, duben…

### Úklid

Skryj (pravé tlačítko → *Skrýt v zobrazení sestavy*) všechny technické
sloupce, na které uživatel reportu nemá sahat: `date_key`, `station_id`,
`*_sort` a klíčové sloupce ve faktových tabulkách. V seznamu polí pak
zůstane jen to, co dává smysl přetáhnout do vizuálu.

---

## 3. Míry (30 minut)

Založ prázdnou tabulku `Míry` (poslední blok v `power_query.m`), označ ji
a přidávej míry z [`measures.dax`](measures.dax): *Modelování → Nová míra*.

Nedělej to bezmyšlenkovitě. U každé míry si přečti komentář nad ní — jsou
tam přeložené do SQL nebo pandas, což je přesně ta cesta, po které se DAX
učí nejrychleji, když už SQL umíš.

Formátování nastav hned u založení (*Nástroje měr → Formát*):

| Míra | Formát |
|---|---|
| `Podíl platných čtení`, `Pokrytí období`, `Dostupnost stanice`, `Podíl dopočtených dnů` | Procenta, 1 des. místo |
| `Teplota vody`, `Teplota vzduchu`, `Rozdíl voda − vzduch` | Vlastní: `0.0 "°C"` |
| `Výška hladiny`, `Nejnižší hladina` | Vlastní: `0.0 "cm"` |
| `Dokončeno vývoje` | Vlastní: `0.0 "%"` |
| `Dnů do kuklení`, `Rozdíl modelů` | Vlastní: `0 "dní"` |
| `Nejdelší výpadek` | Vlastní: `0 "h"` |

---

## 4. Stránky reportu (60 minut)

### Stránka 1 — Přehled

```
┌──────────┬──────────┬──────────┬──────────┬──────────┐
│ Dnů      │ Čtení    │ Platných │ Dopočte- │ Dostup-  │  karty
│ s měřením│ celkem   │ čtení %  │ ných dnů%│ nost %   │
├──────────┴──────────┴──────────┴─────┬────┴──────────┤
│  Teplota vody a vzduchu              │  Průřezy:     │
│  spojnicový graf, osa = date         │  • rok        │
│  hodnoty: Teplota vody, Teplota      │  • měsíc      │
│           vzduchu, Teplota vody 7d   │  • sezóna     │
├──────────────────────────────────────┤  • druh       │
│  Výška hladiny                       │               │
│  plošný graf + konstantní čára 2 cm  │               │
└──────────────────────────────────────┴───────────────┘
```

Konstantní čáru přidáš v podokně *Formát vizuálu → Další vlastnosti →
Čára konstanty osy Y*, hodnota 2, popisek „práh vyschnutí".

### Stránka 2 — Vývoj larev

- **Spojnicový graf**: osa `date`, hodnoty `Dokončeno vývoje`, legenda
  `dim_species[species_label]`, průřez `dim_model[model_label]`.
  Přidej konstantní čáry na 40 % a 67 % (hranice instaru 3 a 4).
- **Tabulka**: `dim_species[species_label]`, `fact_development[cohort_id]`,
  míry `Datum kuklení`, `Dnů do kuklení`, `Rozdíl modelů`,
  `Podíl dnů s dopočtenou teplotou v kohortě`.
- **Karta**: `Rozdíl modelů` s dynamickým titulkem `Titulek období`.
- **Karta s textem**: míra `Upozornění na jakost` — objeví se jen tehdy,
  když je podíl dopočtených dnů vysoký.

### Stránka 3 — Jakost dat

- **Matice**: řádky `dim_sensor[category]` a `dim_sensor[sensor_label]`,
  sloupce `dim_quality[quality_label]`, hodnota `Počet čtení`.
  Podmíněné formátování na barvu pozadí.
- **Pruhový graf**: `dim_sensor[sensor_label]` × `Podíl platných čtení`.
- **Tabulka výpadků**: `fact_gap[gap_start]`, `[gap_end]`,
  `[missing_hours]`, `[severity]`, seřazeno sestupně podle hodin.
- **Karty**: `Chybějících hodin`, `Nejdelší výpadek`, `Nefunkčních čidel`.

### Vzhled

Konzistence je vidět víc než barvy. Drž se toho:

- Jedna barva pro vodu (modrá), jedna pro vzduch (oranžová),
  napříč všemi stránkami stejně.
- Vypni všem vizuálům stín a zaoblení, zapni jemné ohraničení.
- Nadpis každého vizuálu jako věta, co ukazuje („Teplota vody sleduje
  vzduch se zpožděním"), ne jako název sloupce.
- Průřezy dej na všechny stránky na stejné místo a synchronizuj je
  (*Zobrazení → Synchronizovat průřezy*).

---

## 5. Co s tím u pohovoru

Report je záminka. Otázky budou o tom, co je za ním. Připrav si tohle:

**„Proč hvězdicové schéma a ne jedna plochá tabulka?"**
Fakty mají tři různá zrna (čtení / den / den × druh × model). V ploché
tabulce by je nešlo míchat, aniž by se násobily řádky. Dimenze navíc drží
popisky a řazení na jednom místě — když se změní název čidla, mění se
v jedné tabulce, ne ve třech faktech.

**„K čemu je v tom modelu tabulka kalendáře, když datum je i ve faktech?"**
Řada má výpadky. Kdyby časová osa vycházela z faktů, „posledních sedm dní"
by znamenalo „posledních sedm řádků s daty" — při třídenním výpadku úplně
jiné okno. Souvislý kalendář drží osu i tam, kde stanice mlčela, a je to
také jediný způsob, jak dát smysl `SAMEPERIODLASTYEAR`.

**„Vysvětli CALCULATE."**
Míra se počítá ve filtrovacím kontextu, který jí dá vizuál. `CALCULATE` je
jediná funkce, která ten kontext umí přepsat. `Platných čtení` je
`Počet čtení` s dodanou podmínkou `quality_key = "OK"` — v SQL by to bylo
`count(*) FILTER (WHERE …)`. `REMOVEFILTERS` naopak filtr sundá; v míře
`Odchylka od průměru období` se díky němu porovnává jeden měsíc proti
celému období.

**„Jak jsi řešil chybějící a vadná data?"**
Nevyhodil jsem je — označil. Každé čtení má příznak jakosti, do modelu
vstupují jen ta v pořádku, ale report ukazuje i ta ostatní. Dvě čidla
srážek vracejí po celou dobu nulu, hladinoměr má doloženou poruchu se
zápornými hodnotami kolem −300 cm. A hlavně: 63 % dnů má teplotu vody
dopočítanou z teploty vzduchu, protože čidla vyčnívala nad hladinu.
To je v reportu jako samostatná míra, ne schované v poznámce pod čarou.

**„Co je na těch datech nejslabší?"**
Právě ten podíl dopočtených dnů. Model vývoje larev stojí na teplotě vody,
a ta je z větší části modelovaná, ne měřená. Report to říká nahlas —
kdybych to schoval, dashboard by vypadal líp a byl by k ničemu.
