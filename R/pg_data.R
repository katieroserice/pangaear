#' Download data from Pangaea.
#'
#' Grabs data as a dataframe or list of dataframes from a Pangaea data
#' repository URI; see: <https://www.pangaea.de/>
#'
#' @export
#' @param doi DOI of Pangaeae single dataset, or of a collection of datasets.
#' Expects either just a DOI of the form `10.1594/PANGAEA.746398`, or with
#' the URL part in front, like
#' <https://doi.pangaea.de/10.1594/PANGAEA.746398>
#' @param overwrite (logical) Ovewrite a file if one is found with the same name
#' @param verbose (logical) print information messages. Default: `TRUE`
#' @param ... Curl options passed on to [httr::GET()]
#' @param prompt (logical) Prompt before clearing all files in cache? No prompt
#' used when DOIs assed in. Default: `TRUE`
#' @return One or more items of class pangaea, each with the doi, parent doi
#' (if many dois within a parent doi), url, citation, path, and data object.
#' Data object depends on what kind of file it is. For tabular data, we print
#' the first 10 columns or so; for a zip file we list the files in the zip
#' (but leave it up to the user to dig unzip and get files from the zip file);
#' for png files, we point the user to read the file in with [png::readPNG()]
#' @author Naupaka Zimmerman, Scott Chamberlain
#' @references <https://www.pangaea.de>
#' @details Data files are stored in an operating system appropriate location.
#' Run `rappdirs::user_cache_dir("pangaear")` to get the storage location
#' on your machine.
#'
#' Some files/datasets require the user to be logged in. For now we
#' just pass on these - that is, give back nothing other than metadata.
#' @examples \dontrun{
#' # a single file
#' (res <- pg_data(doi='10.1594/PANGAEA.807580'))
#' res[[1]]$doi
#' res[[1]]$citation
#' res[[1]]$data
#'
#' # another single file
#' pg_data(doi='10.1594/PANGAEA.807584')
#'
#' # Many files
#' (res <- pg_data(doi='10.1594/PANGAEA.761032'))
#' res[[1]]
#' res[[2]]
#'
#' # Manipulating the cache
#' ## list files in the cache
#' pg_cache_list()
#'
#' ## clear all data
#' # pg_cache_clear()
#' pg_cache_list()
#'
#' ## clear a single dataset by DOI
#' pg_data(doi='10.1594/PANGAEA.812093')
#' pg_cache_list()
#' pg_cache_clear(doi='10.1594/PANGAEA.812093')
#' pg_cache_list()
#'
#' ## clear more than 1 dataset by DOI
#' lapply(c('10.1594/PANGAEA.746398','10.1594/PANGAEA.746400'), pg_data)
#' pg_cache_list()
#' pg_cache_clear(doi=c('10.1594/PANGAEA.746398','10.1594/PANGAEA.746400'))
#' pg_cache_list()
#'
#' # search for datasets, then pass in DOIs
#' (searchres <- pg_search(query = 'birds', count = 20))
#' pg_data(searchres$doi[1])
#' pg_data(searchres$doi[2])
#' pg_data(searchres$doi[3])
#' pg_data(searchres$doi[4])
#' pg_data(searchres$doi[7])
#'
#' # png file
#' pg_data(doi = "10.1594/PANGAEA.825428")
#'
#' # zip file
#' pg_data(doi = "10.1594/PANGAEA.860500")
#'
#' # login required
#' ## we skip file download
#' pg_data("10.1594/PANGAEA.788547")
#' }

pg_data <- function(doi, overwrite = TRUE, verbose = TRUE, ...) {
  dois <- check_many(doi)
  citation <- attr(dois, "citation")
  if (verbose) message("Downloading ", length(dois), " datasets from ", doi)
  invisible(lapply(dois, function(x) {
    if ( !is_pangaea(env$path, x) ) {
      pang_GET(url = paste0(base(), x), doi = x, overwrite, ...)
    }
  }))
  if (verbose) message("Processing ", length(dois), " files")
  out <- process_pg(dois, doi, citation)
  lapply(out, structure, class = "pangaea")
}

#' @export
print.pangaea <- function(x, ...) {
  cat(sprintf("<Pangaea data> %s", x$doi), sep = "\n")
  cat(sprintf("  parent doi: %s", x$parent_doi), sep = "\n")
  cat(sprintf("  url:        %s", x$url), sep = "\n")
  cat(sprintf("  citation:   %s", x$citation), sep = "\n")
  cat(sprintf("  path:       %s", x$path), sep = "\n")
  cat("  data:", sep = "\n")
  print(x$data)
}

pang_GET <- function(url, doi, overwrite, ...){
  dir.create(env$path, showWarnings = FALSE, recursive = TRUE)
  res <- httr::GET(url, query = list(format = "textfile"),
                   httr::config(followlocation = TRUE), ...)
  httr::stop_for_status(res)
  # if login required, stop with just metadata
  if (grepl("text/html", res$headers$`content-type`)) {
    if (
      grepl("Log in",
            xml2::xml_text(
              xml2::xml_find_first(xml2::read_html(cuf8(res)), "//title")))
    ) {
      warning("Log in required, skipping file download", call. = FALSE)
      return()
    }
  }

  fname <- rdoi(
    doi,
    switch(
      res$headers$`content-type`,
      `image/png` = ".png",
      `text/tab-separated-values;charset=UTF-8` = ".txt",
      `application/zip` = ".zip"
    )
  )
  switch(
    res$headers$`content-type`,
    `image/png` = png::writePNG(httr::content(res), file.path(env$path, fname)),
    `text/tab-separated-values;charset=UTF-8` = {
      writeLines(httr::content(res, "text"), file.path(env$path, fname))
    },
    `application/zip` = {
      path <- file(file.path(env$path, fname), "wb")
      writeBin(res$content, path)
      close(path)
    }
  )
}

process_pg <- function(x, doi, citation) {
  lapply(x, function(m) {
    file <- list.files(env$path, pattern = gsub("/|\\.", "_", m),
                       full.names = TRUE)
    if (length(file) == 0) {
      list(
        parent_doi = doi,
        doi = m,
        citation = citation,
        url = paste0("https://doi.org/", m),
        path = NA,
        data = NA
      )
    } else {
      list(
        parent_doi = doi,
        doi = m,
        citation = citation,
        url = paste0("https://doi.org/", m),
        path = file,
        data = {
          ext <- strsplit(basename(file), "\\.")[[1]][2]
          switch(
            ext,
            zip = utils::unzip(file, list = TRUE),
            txt = {
              dat <- read_csv(file)
              tibble::as_data_frame(dat, validate = FALSE)
            },
            png = "png; read with png::readPNG()"
          )
        }
      )
    }
  })
}

is_pangaea <- function(x, doi){
  lf <- list.files(x)
  if ( identical(lf, character(0)) ) { FALSE } else {
    doipaths <- unname(vapply(lf, function(z) strsplit(z, "\\.")[[1]][1], ""))
    any(strsplit(rdoi(doi), "\\.")[[1]][1] %in% doipaths)
  }
}

rdoi <- function(x, ext = ".txt") paste0(gsub("/|\\.", "_", x), ext)

check_many <- function(x){
  res <- httr::GET(fix_doi(x))
  txt <- xml2::read_html(cuf8(res))
  dc_format <- xml2::xml_attr(
    xml2::xml_find_first(txt, "//meta[@name=\"DC.format\"]"), "content")
  cit <- xml2::xml_text(
    xml2::xml_find_first(txt, "//h1[@class=\"MetaHeaderItem citation\"]"))
  attr(x, "citation") <- cit

  if (grepl("zip", dc_format) && !grepl("datasets", dc_format)) {
    # zip files
    return(x)
  } else if (
    # single dataset
    unique(xml2::xml_length(
      xml2::xml_find_all(
        txt,
        ".//div[@class=\"MetaHeaderItem\"]//a[@rel=\"follow\"]"
      )
    )) == 0
  ) {
    return(x)
  } else {
    # many datasets
    tmp <- gsub(
      "https://doi.pangaea.de/", "",
      xml2::xml_attr(
        xml2::xml_find_all(txt,
            ".//div[@class=\"MetaHeaderItem\"]//a[@rel=\"follow\"]"
        ),
        "href"
      )
    )
    attr(tmp, "citation") <- cit
    return(tmp)
  }
}

fix_doi <- function(x) {
  if (grepl("https?://doi.pangaea.de/?", x)) {
    x
  } else {
    # make sure doi is cleaned up before making a url
    if (!grepl("^10.1594", x)) {
      stop(x, " not of right form, expecting a DOI, see pg_data help file",
           call. = FALSE)
    }
    paste0(base(), x)
  }
}
