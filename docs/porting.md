# Adding temperature sensors for a new chip

Fans work on every Apple Silicon Mac with fans. Temperatures need a list of
SMC keys for each chip family, in `temperatureKeys()` in `src/smcfan.swift`.
Today there are lists for `M1` and `M4`.

1. Install smcfan on the machine and take two key dumps, one idle and one
   under load (e.g. `yes > /dev/null &` once per core, or a GPU benchmark):

   ```bash
   smcfan dump-keys && cp /var/run/smcfan/keys.tsv idle.tsv
   # start the load, wait ~30 s
   smcfan dump-keys && cp /var/run/smcfan/keys.tsv load.tsv
   ```

   `dump-keys` only reads; it costs no writes.

2. Look at the `T*` keys of type `flt `:

   ```bash
   join -t $'\t' -j 2 <(awk -F'\t' '$3=="flt " && $2~/^T/' idle.tsv | sort -t $'\t' -k2) \
                      <(awk -F'\t' '$3=="flt " && $2~/^T/' load.tsv | sort -t $'\t' -k2) \
     | awk -F'\t' '{printf "%s\t%s\t%s\n", $1, $5, $9}'
   ```

   Keep the keys that
   - read a plausible temperature (20–110 °C) in **both** dumps,
   - rise under load,
   - are never `0.000`, `1.500`, or exactly `40.000`. Those are
     placeholders from power-gated clusters, and a key that shows one only
     some of the time will make the average jump around.

   On the families seen so far, CPU keys start with `Tp`, `Te` or `Tex`, and
   GPU keys with `Tg`.

3. Add a `case "M3":` (or whichever) to `temperatureKeys()` with the CPU and
   GPU lists, and a one-line comment saying which machine and macOS version
   you checked on.

4. `make check`, rebuild, `sudo build/smcfan install`, and confirm that
   `smcfan` shows stable values that react to load.
