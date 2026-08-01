#!/bin/bash
# THE JOIN-COST GRID, JUDGED AGAINST RECORDED ENGINE TRUTH.
#
# The engine's own PLAN for a join is the only oracle for a join cost
# model, and it is expensive to collect: a grid over two cardinalities
# and several index shapes is hundreds of PREPAREs against a populated
# database. So the grid is RECORDED once, as a TSV of raw plan text
# under /tmp/fbhandson/optgrid, and this gate REPLAYS it: for every row
# it runs fcopt on the same statement against the same database and
# compares the plan SHAPE with the engine's recorded answer.
#
#   qa/opt-grid.sh <recorded-truth.tsv> <database.fdb>
#
# WHY THIS IS STRICTER THAN qa/opt-plans.sh.
# That gate's grid phases (phase 3 near line 335, and phase 4 near line
# 386 - `elif [ "${got:0:7}" = "REFUSED" ]; then srefused=...`, with the
# verdict `if [ $swrong -eq 0 ]`) count a REFUSAL as a pass. That is the
# right rule for a gate whose contract is "match or stay silent", but it
# is the wrong rule for MEASURING a cost model, because a model that
# refuses everything scores a clean sheet. THE ENGINE ALWAYS ANSWERS. So
# here every cell lands in exactly one of THREE outcomes -
#
#   AGREE     fcopt printed the engine's recorded shape
#   DISAGREE  fcopt printed a DIFFERENT shape
#   REFUSED   fcopt printed no shape at all (REFUSED:, or any error)
#
# - and only AGREE counts. A refusal is a disagreement here.
#
# INPUT FORMAT. A tab-separated file, one cell per line, with a header
# line naming the columns (leading '#' optional). The gate needs two
# things from each row: the engine's RAW plan text, and enough to
# rebuild the statement that produced it.
#
#   engine plan   engine_plan | raw_plan | plan | engine
#   statement     sql | statement | query            (preferred)
#     ...or       outer_table + inner_table          (rebuilt via $OPTGRID_SQL)
#     ...or       outer_rows  + inner_rows           (rebuilt via the name templates)
#
# Columns it does not recognise (shape, ratio, a recorded fcopt answer,
# notes) are ignored - in particular a recorded fcopt column is NEVER
# read, because the point is to re-run the binary as it is now.
#
# Environment:
#   OPTGRID_FIELDS   comma/tab list of column names, for a headerless file
#   OPTGRID_SQL      statement template; {OUTER} and {INNER} are the tables
#   OPTGRID_OUTER    table-name template from a row count, default 'A{ROWS}'
#   OPTGRID_INNER    ditto for the inner side, default 'B{ROWS}'
#   OPTGRID_NO_ENGINE=1  skip the drift check described below
#   FCOPT, ISQL, ISC_USER, ISC_PASSWORD as elsewhere in qa/
#
# TWO ASSERTIONS BEFORE ANY CELL IS SCORED, because a harness that
# silently compares against the wrong thing is worse than no harness:
#
#   1. every table the rebuilt statements name must EXIST in the
#      database given as $2. A reconstruction that does not fit the
#      database is reported and the run stops - it is not quietly
#      replaced by a different fixture.
#   2. the DRIFT check: the recorded plan is re-measured against the
#      live engine, row by row. A TSV recorded against a database that
#      has since been rebuilt, re-loaded or re-analysed is no longer
#      ground truth, and scoring a model against it would manufacture
#      both false passes and false failures. Drift fails the gate.

set -u
FCOPT="${FCOPT:-$(dirname "$0")/../target/release/fcopt}"
ISQL="${ISQL:-isql}"
U="${ISC_USER:-SYSDBA}"; P="${ISC_PASSWORD:-masterkey}"
# NOT written as ${OPTGRID_SQL:-...default...}: the default contains a
# '}', which closes the parameter expansion and silently truncates the
# template. That produced a statement the engine could not parse and a
# table-existence check that matched nothing - a whole grid of manufactured
# refusals. Assigned in two steps instead, and every rebuilt statement is
# checked for a surviving '{' below.
SQL_TPL='SELECT O.ID, I.ID FROM {OUTER} O JOIN {INNER} I ON I.K = O.K'
OUTER_TPL='A{ROWS}'
INNER_TPL='B{ROWS}'
[ -n "${OPTGRID_SQL:-}" ]   && SQL_TPL="$OPTGRID_SQL"
[ -n "${OPTGRID_OUTER:-}" ] && OUTER_TPL="$OPTGRID_OUTER"
[ -n "${OPTGRID_INNER:-}" ] && INNER_TPL="$OPTGRID_INNER"

if [ $# -ne 2 ]; then
    echo "usage: qa/opt-grid.sh <recorded-truth.tsv> <database.fdb>"
    exit 2
fi
TSV="$1"; DB="$2"

# SKIP, not FAIL, when the tool under test is absent - the convention of
# every other gate here (serve-real-charset.sh, serve-real-idxcost.sh).
# fcopt is a CLI, so there is no server to start and none to prove alive.
[ -x "$FCOPT" ] || { echo "SKIP fcopt not built ($FCOPT)"; exit 0; }
[ -f "$TSV" ] || { echo "FAIL no such truth file: $TSV"; exit 1; }
[ -f "$DB" ]  || { echo "FAIL no such database: $DB"; exit 1; }

have_isql=1
command -v "$ISQL" >/dev/null 2>&1 || have_isql=0

# --- plan text -> comparable shape -------------------------------------
# The RAW text is what gets recorded and what gets printed on a
# disagreement; the comparison runs on a normalised form so that
# whitespace, the quoting of identifiers and the PUBLIC. schema prefix
# cannot decide a cell. Index NAMES are kept: both sides are looking at
# the same database, so a different index is a different decision.
norm() {
    printf '%s' "$1" | tr '\n\t' '  ' | tr -s ' ' \
        | sed 's/"//g; s/PUBLIC\.//g; s/^ *//; s/ *$//' \
        | tr '[:lower:]' '[:upper:]'
}
# ...and a COARSE class, reported beside the raw text rather than in
# place of it: the join operator, then each stream in plan order with
# the access method it was given.
classify() {
    n=$(norm "$1")
    case "$n" in
        REFUSED*) printf 'REFUSED'; return ;;
        '')       printf '(empty)'; return ;;
    esac
    op=$(printf '%s' "$n" | sed -n 's/^PLAN \([A-Z]*\).*/\1/p')
    [ -z "$op" ] && op="SINGLE"
    st=$(printf '%s' "$n" | grep -oE '[A-Z0-9_$]+ (NATURAL|INDEX|ORDER)' \
         | tr '\n' ',' | sed 's/,$//')
    printf '%s[%s]' "$op" "$st"
}

# --- columns ------------------------------------------------------------
first=$(grep -v '^[[:space:]]*$' "$TSV" | head -1)
hdr=""
if [ -n "${OPTGRID_FIELDS:-}" ]; then
    hdr=$(printf '%s' "$OPTGRID_FIELDS" | tr ',' '\t')
    src="\$OPTGRID_FIELDS"
elif printf '%s' "$first" | grep -q '^#'; then
    hdr=$(printf '%s' "$first" | sed 's/^#//')
    src="the file's header line"
else
    # A headerless file. ONE layout is inferred, and only one: the seven
    # columns the recording scripts under /tmp/fbhandson/optgrid emit
    # (qa-style: outer, inner, shape, tables, engine, fcopt). The
    # inference is ANNOUNCED, never silent, and anything else is refused
    # rather than guessed at.
    nf=$(printf '%s' "$first" | awk -F'\t' '{print NF}')
    f6=$(printf '%s' "$first" | cut -f6)
    if [ "$nf" = "7" ] && printf '%s' "$f6" | grep -qiE '^(PLAN|REFUSED)'; then
        hdr=$(printf 'outer_rows\tinner_rows\tshape\touter_table\tinner_table\tengine_plan\tfcopt_recorded')
        src="an INFERRED 7-column layout (no header in the file)"
    else
        echo "FAIL $TSV has no header line and no layout I recognise ($nf columns)."
        echo "     first line: $first"
        echo "     Add a '#'-prefixed header naming the columns, or set OPTGRID_FIELDS."
        exit 1
    fi
fi

c_sql=0; c_ot=0; c_it=0; c_or=0; c_ir=0; c_eng=0; c_tag=0; n=0
while IFS= read -r name; do
    n=$((n + 1))
    case "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | tr -d ' ')" in
        sql|statement|query|stmt)                 c_sql=$n ;;
        outer_table|outer_tab|outer|otable|at)    c_ot=$n ;;
        inner_table|inner_tab|inner|itable|bt)    c_it=$n ;;
        outer_rows|orows|outer_n)                 c_or=$n ;;
        inner_rows|irows|inner_n)                 c_ir=$n ;;
        engine_plan|raw_plan|plan|engine|eng)     c_eng=$n ;;
        cell|label|case|name)                     c_tag=$n ;;
    esac
done <<EOF
$(printf '%s' "$hdr" | tr '\t' '\n')
EOF

if [ "$c_eng" = 0 ]; then
    echo "FAIL $TSV has no engine-plan column (looked for engine_plan/raw_plan/plan/engine)."
    echo "     columns, from $src: $(printf '%s' "$hdr" | tr '\t' ' ')"
    echo "     A file of fcopt answers is not engine truth; this gate needs the engine's."
    exit 1
fi
mode=""
if   [ "$c_sql" != 0 ];                       then mode="sql"
elif [ "$c_ot" != 0 ] && [ "$c_it" != 0 ];    then mode="tables"
elif [ "$c_or" != 0 ] && [ "$c_ir" != 0 ];    then mode="rows"
else
    echo "FAIL $TSV gives no way to rebuild the statement: no sql column, no"
    echo "     outer_table/inner_table pair, no outer_rows/inner_rows pair."
    echo "     columns, from $src: $(printf '%s' "$hdr" | tr '\t' ' ')"
    exit 1
fi

echo "truth    $TSV"
echo "database $DB"
echo "columns  $(printf '%s' "$hdr" | tr '\t' ' ')   (from $src)"
case "$mode" in
    sql)    echo "statement taken VERBATIM from the file" ;;
    tables) echo "statement rebuilt: $SQL_TPL" ;;
    rows)   echo "statement rebuilt: $SQL_TPL"
            echo "          tables:  outer=$OUTER_TPL inner=$INNER_TPL  (from the row counts)" ;;
esac

# --- read the rows ------------------------------------------------------
rows=0
declare -a Q_ARR ENG_ARR TAG_ARR
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        '#'*) continue ;;
        '')   continue ;;
    esac
    [ -n "$hdr" ] && [ "$line" = "$first" ] && [ "$src" = "the file's header line" ] && continue
    IFS=$'\t' read -r -a f <<< "$line"
    get() { i=$1; [ "$i" = 0 ] && { printf ''; return; }; printf '%s' "${f[$((i - 1))]:-}"; }
    eng=$(get "$c_eng")
    [ -z "$eng" ] && continue
    case "$mode" in
        sql)
            q=$(get "$c_sql") ;;
        tables)
            ot=$(get "$c_ot"); it=$(get "$c_it")
            q=${SQL_TPL//\{OUTER\}/$ot}; q=${q//\{INNER\}/$it} ;;
        rows)
            ot=${OUTER_TPL//\{ROWS\}/$(get "$c_or")}
            it=${INNER_TPL//\{ROWS\}/$(get "$c_ir")}
            q=${SQL_TPL//\{OUTER\}/$ot}; q=${q//\{INNER\}/$it} ;;
    esac
    if [ -z "$q" ]; then
        echo "FAIL row $((rows + 1)) has no statement and none could be rebuilt: $line"
        exit 1
    fi
    case "$q" in
        *'{'*|*'}'*)
            echo "FAIL row $((rows + 1)) still holds a template placeholder after substitution:"
            echo "     $q"
            echo "     (check OPTGRID_SQL / OPTGRID_OUTER / OPTGRID_INNER)"
            exit 1 ;;
    esac
    tag="$(get "$c_or")x$(get "$c_ir")"
    [ "$tag" = "x" ] && tag="$(get "$c_tag")"
    [ -z "$tag" ] && tag="row$((rows + 1))"
    [ "$mode" = tables ] && tag="$tag ${ot}/${it}"
    Q_ARR[$rows]="$q"; ENG_ARR[$rows]="$eng"; TAG_ARR[$rows]="$tag"
    rows=$((rows + 1))
done < "$TSV"

if [ "$rows" = 0 ]; then
    echo "FAIL $TSV holds no scoreable rows"
    exit 1
fi

# --- assertion 1: the statements name tables THIS database has ----------
if [ "$have_isql" = 1 ]; then
    known=$("$ISQL" -q -b -user "$U" -pas "$P" "$DB" 2>/dev/null <<'SQL' | tr -d ' \r'
SET HEADING OFF;
SELECT RDB$RELATION_NAME FROM RDB$RELATIONS WHERE RDB$SYSTEM_FLAG = 0;
SQL
)
    missing=""
    for name in $(printf '%s\n' "${Q_ARR[@]}" | grep -oE '(FROM|JOIN) +[A-Za-z0-9_$]+' \
                  | awk '{print toupper($2)}' | sort -u); do
        printf '%s\n' "$known" | grep -qx "$name" || missing="$missing $name"
    done
    if [ -n "$missing" ]; then
        echo "FAIL the rebuilt statements name tables this database does not have:$missing"
        echo "     $TSV was recorded against a different fixture. Give the database it"
        echo "     was recorded against, or set OPTGRID_OUTER/OPTGRID_INNER/OPTGRID_SQL."
        exit 1
    fi
    echo "OK       every table named exists in $DB"
else
    echo "NOTE     isql not found - table existence and engine drift NOT checked"
fi

# --- the scoring loop ---------------------------------------------------
agree=0; disagree=0; refused=0; drift=0
do_engine=1
[ "$have_isql" = 1 ] || do_engine=0
[ "${OPTGRID_NO_ENGINE:-0}" = 1 ] && { do_engine=0; echo "NOTE     drift check disabled by OPTGRID_NO_ENGINE"; }

i=0
while [ $i -lt $rows ]; do
    q="${Q_ARR[$i]}"; eng="${ENG_ARR[$i]}"; tag="${TAG_ARR[$i]}"
    i=$((i + 1))

    got=$("$FCOPT" plan "$DB" "$q" 2>&1); rc=$?
    got=$(printf '%s' "$got" | grep -v '^$' | head -1)

    # assertion 2: is the RECORDED plan still what the engine says?
    if [ "$do_engine" = 1 ]; then
        live=$("$ISQL" -q -user "$U" -pas "$P" "$DB" 2>&1 <<SQL | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | head -1
SET PLANONLY ON;
$q;
SQL
)
        if [ "$(norm "$live")" != "$(norm "$eng")" ]; then
            echo "DRIFT    [$tag] the recorded truth is not what the engine says now"
            echo "         recorded: $eng"
            echo "         engine:   $live"
            drift=$((drift + 1))
        fi
    fi

    if [ "$(norm "$got")" = "$(norm "$eng")" ] && [ "$rc" = 0 ]; then
        agree=$((agree + 1))
        continue
    fi
    case "$got" in
        REFUSED*)
            # A REFUSAL IS A DISAGREEMENT. The engine answered this cell;
            # fcopt did not. Counting it as a pass (qa/opt-plans.sh does,
            # by design, in its grid phases) would let a model that
            # refuses the whole band score perfectly on it.
            echo "REFUSED  [$tag] $q"
            echo "         engine: $eng   ($(classify "$eng"))"
            echo "         fcopt:  $got"
            refused=$((refused + 1)) ;;
        *)
            if [ "$rc" != 0 ]; then
                echo "REFUSED  [$tag] fcopt failed (exit $rc): $q"
                echo "         engine: $eng   ($(classify "$eng"))"
                echo "         fcopt:  ${got:-(no output)}"
                refused=$((refused + 1))
            else
                echo "DISAGREE [$tag] $q"
                echo "         engine: $eng   ($(classify "$eng"))"
                echo "         fcopt:  $got   ($(classify "$got"))"
                disagree=$((disagree + 1))
            fi ;;
    esac
done

echo "$agree/$rows cells agree   ($disagree disagree, $refused refused)"
[ "$drift" -gt 0 ] && echo "         $drift of $rows recorded cells DRIFTED - the truth file is stale for this database"

[ "$agree" = "$rows" ] && [ "$drift" = 0 ] && exit 0
exit 1
