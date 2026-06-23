#!/bin/bash

# ============================================================
# VIIRS Direct Broadcast Processing Pipeline
#
# This script watches two directories for newly received VIIRS
# telemetry files:
#   - NOAA-20 (JPSS-1)
#   - Suomi-NPP
#
# Required software:
#   - RT-STPS
#   - CSSP
#   - Polar2Grid
# Inotifywait library (for directory watching) is installed in conda environment "viirs"
#
# When a new file arrives:
#   1. Wait until the file is completely written.
#   2. Process raw telemetry using RT-STPS.
#   3. Generate SDR products using the CSSP pipeline.
#   4. Create georeferenced GeoTIFFs using Polar2Grid.
#   5. Clean intermediate files.
#
# Output:
#   GeoTIFF products are saved in separate folders for each
#   satellite.
#
# TODO:
#   - Preserve CSSP-generated VIIRS SDR products.
#   - Develop direct boat detection from DNB SDR radiance files.
#   - Remove Polar2Grid dependency for operational boat detection.
#   - Use Polar2Grid only for quicklook and visualization products.
# ============================================================
#
# ============================================================
# DIRECTORY CONFIGURATION
# ============================================================

# Directory monitored for incoming NOAA-20 telemetry files
WATCH_DIR_NOAA20="/home/arlo.sabuito/proj_datos/VIIRS/watcher_noaa20"

# Directory monitored for incoming Suomi-NPP telemetry files
WATCH_DIR_NPP="/home/arlo.sabuito/proj_datos/VIIRS/watcher_npp"

# RT-STPS installation directory
RTSTPS_DIR="/home/arlo.sabuito/rt-stps"

# RT-STPS XML configuration for NOAA-20
CONFIG_NOAA20="$RTSTPS_DIR/config/jpss1.xml"

# RT-STPS XML configuration for Suomi-NPP
CONFIG_NPP="$RTSTPS_DIR/config/npp.xml"

# CSSP working/output directory
CSSP_OUT="/home/arlo.sabuito/proj_datos/VIIRS/CSSP_out"

# RT-STPS output directory
# RT-STPS writes extracted RDR files here
RTSTPS_OUT="/home/arlo.sabuito/proj_datos/VIIRS/RT_STPS_out"

# Base Polar2Grid output path
# Satellite suffixes are appended later:
#   Polar2Grid_out_NOAA20
#   Polar2Grid_out_SNPP
P2G_OUT="/home/arlo.sabuito/proj_datos/VIIRS/Polar2Grid_out"


# ============================================================
# SCRIPT STARTUP
# ============================================================

echo "======================================="
echo "Watcher started at $(date)"
echo "Watching directories:"
echo "  NOAA-20 : $WATCH_DIR_NOAA20"
echo "  NPP     : $WATCH_DIR_NPP"
echo "======================================="

# Change to RT-STPS installation directory
cd "$RTSTPS_DIR" || exit 1


# ============================================================
# FUNCTION: ensure_server_running
#
# RT-STPS requires its server process to be running before
# telemetry files can be processed.
#
# This function:
#   - Checks current server status
#   - Starts server if not running
#   - Waits until server is ready
# ============================================================

ensure_server_running() {

    STATUS_OUTPUT=$(./jsw/bin/rt-stps-server.sh status 2>&1)

    if echo "$STATUS_OUTPUT" | grep -qi "not running"; then

        echo "[INFO] RT-STPS server not running. Starting..."
        ./jsw/bin/rt-stps-server.sh start

        echo "[INFO] Waiting for server to be ready..."

        while true; do
            sleep 2

            STATUS_OUTPUT=$(./jsw/bin/rt-stps-server.sh status 2>&1)

            if ! echo "$STATUS_OUTPUT" | grep -qi "not running"; then
                echo "[INFO] Server is now running."
                break
            fi
        done

    else
        echo "[INFO] RT-STPS server already running."
    fi
}


# ============================================================
# FUNCTION: wait_until_stable
#
# Purpose:
# Wait until the incoming file is no longer growing.
#
# This prevents processing a telemetry file that is still
# being copied or written by the acquisition system.
#
# Logic:
#   - Check file size every 2 seconds
#   - Require same size for 2 consecutive checks
# ============================================================

wait_until_stable() {

    FILE="$1"

    stable_count=0
    prev_size=-1

    echo "[INFO] Waiting for file to stabilize: $FILE"

    while true; do

        if [ ! -f "$FILE" ]; then
            echo "[WARN] File disappeared: $FILE"
            return 1
        fi

        curr_size=$(stat -c%s "$FILE")

        if [ "$curr_size" -eq "$prev_size" ]; then
            stable_count=$((stable_count + 1))
        else
            stable_count=0
        fi

        if [ "$stable_count" -ge 2 ]; then
            echo "[INFO] File is stable: $FILE"
            break
        fi

        prev_size="$curr_size"
        sleep 2
    done
}


# ============================================================
# Start RT-STPS server before entering watch mode
# ============================================================

ensure_server_running


# ============================================================
# MAIN WATCH LOOP
#
# Monitor both watcher directories using inotify.
#
# Events watched:
#   close_write : file writing completed
#   moved_to    : file moved into directory
#
# Output format:
#   directory|filename
# ============================================================

inotifywait -m \
    -e close_write \
    -e moved_to \
    --format "%w|%f" \
    "${WATCH_DIR_NOAA20}" "${WATCH_DIR_NPP}" | while IFS='|' read DIR FILE

do

    # Construct full file path
    FULL_PATH="${DIR}${FILE}"

    echo "[EVENT] Detected file: $FULL_PATH"

    # Wait until file is fully written
    wait_until_stable "$FULL_PATH" || continue

    # Ensure RT-STPS working directory
    cd "$RTSTPS_DIR" || exit 1

    # Ensure RT-STPS server is running
    ensure_server_running


    # ========================================================
    # STEP 1: DETERMINE SATELLITE SOURCE
    #
    # Select correct RT-STPS configuration and output
    # directory based on which watcher directory triggered
    # the event.
    # ========================================================

    case "$DIR" in

        "${WATCH_DIR_NOAA20}/")

            CONFIG="${CONFIG_NOAA20}"
            SATELLITE="NOAA20"

            # Final GeoTIFF output directory
            P2G="${P2G_OUT}_NOAA20"

            ;;

        "${WATCH_DIR_NPP}/")

            CONFIG="${CONFIG_NPP}"
            SATELLITE="SUOMI-NPP"

            # Final GeoTIFF output directory
            P2G="${P2G_OUT}_SNPP"

            ;;

        *)

            echo "[ERROR] Unknown source directory: $DIR"
            continue

            ;;
    esac


    # ========================================================
    # STEP 2: RT-STPS
    #
    # Convert raw telemetry stream into RT-STPS products.
    #
    # Input:
    #   Raw .dat telemetry file
    #
    # Output:
    #   HDF5 files written to RTSTPS_OUT
    # ========================================================

    echo "[PROCESS] Starting RT-STPS batch"
    echo "[PROCESS] Satellite: $SATELLITE"
    echo "[PROCESS] Config: $CONFIG"

    ./bin/batch.sh "$CONFIG" "$FULL_PATH"

    echo "[DONE] RT-STPS finished: $FULL_PATH"

    # Stop RT-STPS server after processing
    ./jsw/bin/rt-stps-server.sh stop


    # ========================================================
    # STEP 3: CSSP SDR GENERATION
    #
    # Generate VIIRS SDR products from RT-STPS output.
    # -p is number of processors, Davao ground station viirs telemetry data usually has 8 to 9 granules to process
    #
    # Input:
    #   RTSTPS_OUT/RNSCA-RVIRS_*.h5
    #
    # Output:
    #   SDR files in CSSP_OUT
    # ========================================================

    echo "[PROCESS] Starting CSSP Pipeline"

    viirs_sdr.sh \
        -W "$CSSP_OUT" \
        -p 9 \
        "$RTSTPS_OUT"/RNSCA-RVIRS_*.h5

    echo "[DONE] CSSP Pipeline finished"


    # ========================================================
    # STEP 4: POLAR2GRID
    #
    # Convert VIIRS SDR products into georeferenced
    # GeoTIFF images.
    #
    # Product:
    #   dynamic_dnb (Day/Night Band) This is purely for Visualization
    #
    # Projection:
    #   WGS84
    #
    # Output:
    #   Polar2Grid_out_NOAA20/*.tif
    #   Polar2Grid_out_SNPP/*.tif
    # ========================================================

    echo "[PROCESS] Starting Polar2Grid"

    BASE_FILE=$(basename "$FILE" .dat)

    $POLAR2GRID_HOME/bin/polar2grid.sh \
        -r viirs_sdr \
        -w geotiff \
        --output-filename "$P2G/${BASE_FILE}.tif" \
        -p DNB \
        --dtype float32 \
        -g wgs84_fit \
        --grid-coverage=.25 \
        --fill-value 0 \
        -v \
        -f "$CSSP_OUT"

    echo "[DONE] Polar2Grid finished"


    # ========================================================
    # STEP 5: CLEANUP
    #
    # Remove intermediate files to avoid filling disk.
    #
    # The final GeoTIFF product remains in the P2G output
    # directory.
    # ========================================================

    echo "[INFO] Cleaning intermediate folders"

    find "$CSSP_OUT" -mindepth 1 -delete
    find "$RTSTPS_OUT" -mindepth 1 -delete

    echo "[PIPELINE DONE] $FULL_PATH"
    echo "---------------------------------------"

done
