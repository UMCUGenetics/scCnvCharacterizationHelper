## Copyright (C) 2021  Roel Janssen <roel@gnu.org>

## This program is free software: you can redistribute it and/or modify
## it under the terms of the GNU General Public License as published by
## the Free Software Foundation, either version 3 of the License, or
## (at your option) any later version.

#' Run AneuFinder for all cells of a donor.
#'
#' @param output_directory         The directory to write output to.
#' @param donor                    The name of the donor to find cells for.
#' @param samplesheet              A data frame of the samplesheet.
#' @param numCPU                   The number of CPUs to use.
#' @param copyNumberCallingBinSize The bin size to use for copy number calling.
#' @param blacklist.file           The blacklist file to use.
#' @param sequenceability.file     The sequenceability factors file to use.
#' @param correction.method        The correction method to apply.
#' @param plotting                 Whether plots should be generated.
#' @param reference.genome         The BSgenome to use as reference genome.
#'
#' @importFrom AneuFinder Aneufinder
#'
#' @export

runAneufinderForDonor <- function (output_directory,
                                   donor,
                                   samplesheet,
                                   numCPU,
                                   copyNumberCallingBinSize,
                                   blacklist.file=NULL,
                                   sequenceability.file=NULL,
                                   correction.method=c("GC"),
                                   plotting=FALSE,
                                   reference.genome)
{
    outputTempFolder       <- paste0 (output_directory, "/.tmp_", donor)
    aneufinderOutputFolder <- paste0 (output_directory, "/", donor)

    dir.create (outputTempFolder, showWarnings = FALSE, recursive = TRUE)
    dir.create (aneufinderOutputFolder, showWarnings = FALSE, recursive = TRUE)

    for (filepath in samplesheet$filename)
    {
        name        <- basename (filepath)
        destination <- paste0(outputTempFolder, "/", name)

        file.symlink (filepath, destination)
        file.symlink (paste0 (filepath, ".bai"), paste0 (destination, ".bai"))
    }

    Aneufinder (inputfolder            = outputTempFolder,
                outputfolder           = aneufinderOutputFolder,
                assembly               = 'bosTau8',
                numCPU                 = numCPU,
                binsizes               = copyNumberCallingBinSize,
                stepsizes              = copyNumberCallingBinSize,
                correction.method      = correction.method,
                chromosomes            = c(1:29, "X"),
                remove.duplicate.reads = TRUE,
                reads.store            = FALSE,
                blacklist              = blacklist.file,
                strandseq              = FALSE,
                GC.BSgenome            = reference.genome,
                states                 = c("zero-inflation", paste0(0:10, "-somy")),
                method                 = c("edivisive"),
                min.mapq               = 10,
                sequenceability.file   = sequenceability.file,
                stop.after.binning     = !plotting)

    unlink (outputTempFolder, recursive = TRUE)
}

#' Create blacklist
#'
#' @param outputDirectory    The directory to write output to.
#' @param samplesheet        A data frame of the samplesheet.
#' @param blacklistBinSize   The bin size to use for backlisting regions.
#' @param genome             The BSgenome to use as reference.
#' @param allosomes          The allosomal chromosomes to include.
#' @param autosomes          The autosomal chromosomes to include.
#' @param numCPU             The number of CPUs to use.
#'
#' @return The file path to the blacklist regions file.
#'
#' @importFrom AneuFinder exportGRanges
#' @importFrom parallel   mclapply
#'
#' @export

createBlacklistFromSamplesheet <- function (outputDirectory,
                                            samplesheet,
                                            blacklistBinSize,
                                            genome,
                                            allosomes,
                                            autosomes,
                                            numCPU=16)
{
    blacklist.file <- paste0(outputDirectory, "/blacklist_", blacklistBinSize, ".bed.gz")
    if (! file.exists (blacklist.file))
    {
        chromosomeFilter  <- c(autosomes, allosomes)
        coverages         <- mclapply (samplesheet$filename,
                                       function (filename) {
                                           return (coveragePerBin (filename,
                                                                   genome,
                                                                   chromosomeFilter,
                                                                   blacklistBinSize))
                                       }, mc.cores = numCPU)

        totalBinCounts    <- mergeBinCounts (coverages)
        outlierBins       <- determineOutlierRegions (NULL,
                                                      genome,
                                                      blacklistBinSize,
                                                      autosomes,
                                                      allosomes,
                                                      totalBinCounts,
                                                      0.05, 0.95,
                                                      0.05, 0.95)

        ## ".bed.gz" will be appended by the exportGRanges function.
        blacklist.file <- paste0(outputDirectory, "/blacklist_", blacklistBinSize)

        AneuFinder::exportGRanges (outlierBins,
                                   filename = blacklist.file,
                                   header = FALSE,
                                   chromosome.format = "NCBI")

        ## Let the file path match the actually created path.
        blacklist.file <- paste0(blacklist.file, ".bed.gz")
    }

    return(blacklist.file)
}

#' Create sequenceability factors
#'
#' @param outputDirectory          The directory to write output to.
#' @param samplesheet              A data frame of the samplesheet.
#' @param copyNumberCallingBinSize The bin size to use for copy number calling.
#' @param reference.genome         The BSgenome to use as reference.
#' @param numCPU                   The number of CPUs to use.
#'
#' @return The file path to the sequenceability factors file.
#'
#' @importFrom Rsamtools BamFile
#' @importFrom GenomeInfoDb seqlengths
#' @importFrom AneuFinder fixedWidthBins determineSequenceabilityFactors
#'
#' @export

createSequenceabilityFactorsFromSamplesheet <- function (outputDirectory,
                                                         samplesheet,
                                                         copyNumberCallingBinSize,
                                                         reference.genome,
                                                         numCPU=16)
{
    sequenceability.file <- paste0(outputDirectory,
                                   "/sequenceability.factors.",
                                   copyNumberCallingBinSize,
                                   ".gc.RData")

    if (! file.exists (sequenceability.file))
    {
        bamfile       <- samplesheet$filename[1]
        chrom.lengths <- GenomeInfoDb::seqlengths(Rsamtools::BamFile(bamfile))
        bins          <- fixedWidthBins (chrom.lengths = chrom.lengths, chromosomes=c(1:29, "X"),
                                         binsizes      = copyNumberCallingBinSize,
                                         stepsizes     = copyNumberCallingBinSize)

        sequenceability.folder <- paste0 (outputDirectory, "/.tmp_sequenceability_factors")
        runAneufinderForDonor (sequenceability.folder,
                               "Aneufinder",
                               samplesheet,
                               numCPU,
                               copyNumberCallingBinSize,
                               NULL,
                               NULL,
                               c("GC"),
                               plotting=FALSE,
                               reference.genome)

        sequenceability.folder  <- paste0 (sequenceability.folder, "/Aneufinder/binned-GC")
        sequenceability.factors <- determineSequenceabilityFactors (sequenceability.folder, bins)
        save(sequenceability.factors, file=sequenceability.file)
    }

    return(sequenceability.file)
}

#' Run AneuFinder for all samples in the specified samplesheet.
#'
#' @param outputDirectory              The directory to write output to.
#' @param samplesheet                  A data frame of the samplesheet.
#' @param blacklistBinSize             The bin size to use for backlisting regions.
#' @param copyNumberCallingBinSize     The bin size to use for copy number calling.
#' @param genome                       The BSgenome to use as reference.
#' @param allosomes                    The allosomal chromosomes to include.
#' @param autosomes                    The autosomal chromosomes to include.
#' @param applySequenceabilityFactors  Whether to apply sequenceability factors.
#' @param numCPU                       The number of CPUs to use.
#'
#' @export

runAneufinderForSamplesheet <- function (outputDirectory,
                                         samplesheet,
                                         blacklistBinSize,
                                         copyNumberCallingBinSize,
                                         genome,
                                         allosomes,
                                         autosomes,
                                         applySequenceabilityFactors = FALSE,
                                         numCPU = 16)
{
		chromosomeFilter  <- c(autosomes, allosomes)
    sf_samplesheet    <- samplesheet[which (samplesheet$include_in_sf == 1),]

    ## -----------------------------------------------------------------------
    ## CREATE BLACKLIST
    ## -----------------------------------------------------------------------
    blacklist.file <- createBlacklistFromSamplesheet (outputDirectory,
                                                      samplesheet,
                                                      blacklistBinSize,
                                                      genome,
                                                      allosomes,
                                                      autosomes,
                                                      numCPU)

		## -----------------------------------------------------------------------
    ## CREATE SEQUENCEABILITY FACTORS
    ## -----------------------------------------------------------------------

		if (! applySequenceabilityFactors) {
			 sequenceability.file <- NULL
		} else {
        sequenceability.file <- createSequenceabilityFactorsFromSamplesheet (
            outputDirectory,
            sf_samplesheet,
            copyNumberCallingBinSize,
            genome,
            numCPU)
    }

		## -----------------------------------------------------------------------
    ## RUN ANEUFINDER
    ## -----------------------------------------------------------------------

    donors <- unique(samplesheet$donor)
    for (donor in donors)
    {
        donor_samplesheet <- samplesheet[which (samplesheet$donor == donor),]
        runAneufinderForDonor (outputDirectory,
                               donor,
                               donor_samplesheet,
                               numCPU,
                               copyNumberCallingBinSize,
                               blacklist.file,
                               sequenceability.file,
                               correction.method=c("GCSC"),
                               plotting=FALSE,
                               reference.genome=genome)
    }
}

#' Gather quality metrics from AneuFinder output.
#'
#' @param base_directory  The directory in which AneuFinder output was written.
#' @param samplesheet     The samplesheet used to run the pipeline.
#' @param donor           The name of the donor to extract cells for.
#'
#' @return A data frame containing various quality metrics for all cells
#'         associated with the specified donor.

gatherQualityInfoForDonor <- function (base_directory, samplesheet, donor)
{
    donor_samples         <- samplesheet[(samplesheet$donor == donor),][["sample_name"]]
    number_of_samples     <- length(donor_samples)

    ## Pre-allocate numeric arrays
    name          <- character(number_of_samples)
    num.segments  <- numeric(number_of_samples)
    bhattacharyya <- numeric(number_of_samples)
    spikiness     <- numeric(number_of_samples)
    entropy       <- numeric(number_of_samples)
    read.count    <- numeric(number_of_samples)

    ## Look up scores in the data files
    for (sample_index in 1:number_of_samples)
    {
        sample_name  <- donor_samples[sample_index]
        file_name    <- Sys.glob(paste0(base_directory, "/",
                                        donor, "/MODELS/method-edivisive/",
                                        sample_name, "_dedup.bam_*.RData"))

        if (identical(file_name, character(0))) {
            name[sample_index]          <- sample_name
            num.segments[sample_index]  <- NA
            bhattacharyya[sample_index] <- NA
            entropy[sample_index]       <- NA
            spikiness[sample_index]     <- NA
            read.count[sample_index]    <- NA
        }
        else {
            sample       <- get(load(file_name))

            name[sample_index]          <- sample_name
            num.segments[sample_index]  <- sample$qualityInfo$num.segments
            bhattacharyya[sample_index] <- sample$qualityInfo$bhattacharyya
            entropy[sample_index]       <- sample$qualityInfo$entropy
            spikiness[sample_index]     <- sample$qualityInfo$spikiness
            read.count[sample_index]    <- sample$qualityInfo$total.read.count
        }
    }

    output <- data.frame (name, num.segments, bhattacharyya, entropy, spikiness, read.count)

    ## Exclude bin scores that have no read support.
    output$entropy[which(!is.finite(output$entropy))]             <- NA
    output$num.segments[which(!is.finite(output$num.segments))]   <- NA
    output$spikiness[which(!is.finite(output$spikiness))]         <- NA
    output$bhattacharyya[which(!is.finite(output$bhattacharyya))] <- NA

    return (output)
}

#' Exclude cells from the analysis after performing quality control.
#'
#' @param base_directory           The directory in which AneuFinder output was written.
#' @param samplesheet              The samplesheet used to run the pipeline.
#' @param donor                    The name of the donor to extract cells for.
#' @param bhattacharyya_threshold  Threshold for the Bhattacharyya.
#' @param spikiness_threshold      Threshold for the spikiness.
#' @param plotOverlap              Whether to make a Venn diagram to show the overlap
#'                                 between filter criteria.
#'
#' @importFrom ggplot2     ggsave
#' @importFrom VennDiagram venn.diagram
#' @importFrom utils       head tail
#' @importFrom scales      alpha
#'
#' @export

excludedCellsForRun <- function (base_directory,
                                 samplesheet,
                                 donor,
                                 bhattacharyya_threshold=NULL,
                                 spikiness_threshold=NULL,
                                 plotOverlap=FALSE)
{
    run_samplesheet             <- samplesheet[which (samplesheet$donor == donor),]
    scores.df                   <- gatherQualityInfoForDonor (base_directory, samplesheet, donor)

    ncells                      <- nrow(scores.df)
    all_cells                   <- scores.df[["name"]]
    nreads_after_filter         <- scores.df[which(scores.df$read.count > 200000),"name"]

    if (is.null(bhattacharyya_threshold)) {
        bhattacharyya_threshold <- tail(head(sort(scores.df[["bhattacharyya"]]), round(ncells / 10)), 1)
    }
    if (is.null(spikiness_threshold)) {
        spikiness_threshold     <- head(tail(sort(scores.df[["spikiness"]]), round(ncells / 10)), 1)
    }

    bhattacharyya_after_filter  <- scores.df[which(scores.df$bhattacharyya > bhattacharyya_threshold),"name"]
    spikiness_after_filter      <- scores.df[which(scores.df$spikiness < spikiness_threshold),"name"]

    included_cells              <- Reduce(intersect, list(nreads_after_filter,
                                                          bhattacharyya_after_filter,
                                                          spikiness_after_filter))
    excluded_cells              <- setdiff(all_cells, included_cells)

    if (plotOverlap) {
        temp   <- venn.diagram(
            x               = list (nreads_after_filter,
                                    bhattacharyya_after_filter,
                                    spikiness_after_filter),
            category.names  = c ("Reads", "Bhattacharyya", "Spikiness"),
            filename        = NULL,
            width           = 5,
            height          = 5,
            lwd             = 3,
            lty             = 'solid',
            col             = c("#56B4E9", "#E69F00", "#009E73"),
            fill            = c(alpha("#56B4E9",0.4),
                                alpha('#E69F00',0.4),
                                alpha('#009E73',0.4)),
            cex             = .9,
            fontface        = "bold",
            fontfamily      = "sans",
            cat.cex         = .9,
            cat.default.pos = "text",
            cat.pos         = c(0, 0, 0),
            cat.fontfamily  = "sans");

        ggsave(paste0(donor, "_filter_overlap.svg"), temp, width=5, height=5,units="cm", dpi=300)
    }

    return(excluded_cells)
}

#' Remove AneuFinder output of samples.
#'
#' @param base_directory  The directory in which AneuFinder output was written.
#' @param samples         A vector of sample names to exclude.
#'
#' @return The samplesheet without the specified samples.
#'
#' @export

removeExcludedCellsFromOutput <- function (base_directory, samples)
{
    number_of_samples <- length(samples)
    for (sample_index in 1:number_of_samples)
    {
        sample_name   <- samples[sample_index]
        file_name     <- Sys.glob(paste0(base_directory, "/*/MODELS/method-edivisive/",
                                         sample_name, "_dedup.bam_*.RData"))
        if (! identical(file_name, character(0))) {
            file.remove(file_name, showWarnings=FALSE)
        }
    }

    return(TRUE)
}

#' Remove samples from samplesheets.
#'
#' @param samplesheet     The samplesheet used to run the pipeline.
#' @param samples         A vector of sample names to exclude.
#'
#' @return The samplesheet without the specified samples.
#'
#' @export

removeCellsFromSamplesheet <- function (samplesheet, samples)
{
    return(samplesheet[which(! samplesheet$sample_name %in% samples),])
}