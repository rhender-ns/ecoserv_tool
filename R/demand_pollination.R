########################################
### Pollination demand model         ###
### for EcoservR tool                ###
### Sandra Angers-Blondin            ###
### 09 Dec 2020                      ###
########################################


#' Pollination Demand Model
#'
#' Runs the pollination ecosystem service model, generating demand scores based on areas assumed to require insect pollination (crops, gardens, allotments).

#' @param x A basemap, in a list of sf tiles or as one sf object. Must have attribute HabCode_B.
#' @param studyArea The boundaries of the site, as one sf object. The final raster will be masked to this shape. For best results this shape should be smaller than the basemap (which should be buffered by typically 300 m - 1km to avoid edge effects).
#' @param res Desired resolution of the raster. Default is 5 m. Range recommended is 5-10m.
#' @param dist Distance threshold from habitats requiring pollination. Default 800m.
#' @param projectLog The RDS project log file generated by the wizard app and containing all file paths to data inputs and model parameters
#' @param runtitle A customised title you can give a specific model run, which will be appended to your project title in the outputs. If comparing a basemap to an intervention map, we recommend using "pre" and "post", or a short description of the interventions, e.g. "baseline" vs "tree planting".
#' @param save Path to folder where outputs will be saved. By default a folder will be created using your chosen run title, prefixed by "services_". Do not use this argument unless you need to save the outputs somewhere else.
#' @return Two rasters with capacity scores: one with raw scores (0-1: likelihood that a pollinator will visit a pixel), and one rescaled 0-100 (where 100 is maximum capacity for the area).
#' @export
#'
demand_pollination <- function(x = parent.frame()$mm,
                                 studyArea = parent.frame()$studyArea,
                                 res = 10,
                                 dist = 800,
                                 projectLog = parent.frame()$projectLog,
                                 runtitle = parent.frame()$runtitle,
                                 save = NULL
){

  timeA <- Sys.time() # start time

  # Create output directory automatically if doesn't already exist
  if (is.null(save)){

    save <- file.path(projectLog$projpath,
                      paste0("services_", runtitle))

    if (!dir.exists(save)){
      dir.create(save)
    }
  } else {
    # if user specified their own save directory we check that it's ok
    if(!dir.exists(save) | file.access(save, 2) != 0){
      stop("Save directory doesn't exist, or you don't have permission to write to it.")}
  }

  # Create a temp directory for scratch files

  scratch <- file.path(projectLog$projpath,
                       "ecoservR_scratch")

  if(!dir.exists(scratch)){
    dir.create(scratch)
  }


  # if mm is stored in list, combine all before proceeding
  if (isTRUE(class(x) == "list")){
    message("Recombining basemap tiles")
    x <- do.call(rbind, x) %>% sf::st_as_sf()
    # NOT using rbindlist here because only keeps the extent of the first tile
  }

  # drop attributes we don't need
  x <- x %>% dplyr::select(HabCode_B)

  studyArea <- sf::st_zm(studyArea, drop=TRUE) # drop z dimension

  #Check CRS
  x <- checkcrs(x, 27700)
  studyArea <- checkcrs(studyArea, 27700)

  SAbuffer <- sf::st_buffer(studyArea, 500)

  ### Create raster template with same properties as mastermap -----
  r <- terra::rast(crs = "epsg:27700",
                   extent = terra::ext(x),
                   resolution=res) %>%
     terra::crop(., SAbuffer) # buffer so that we avoid edge effects on tile boundaries at focal stage (we'll crop back)


  ### Create core habitat layer -----
  message("Creating layer of land requiring pollination")
  # list of habitats that require pollinators: arable, gardens, orchards
  corehabs <- c(dplyr::filter(ecoservR::hab_lookup,
                            grepl("J11", Ph1code) |
                              HabBroad == "Gardens / Parks / Brownfield")$Ph1code,
                "A11-O", "A112o_T", "A112o")

  x <- dplyr::filter(x, HabCode_B %in% corehabs)


  ### Rasterize -----

  # creates a raster where habitat has value of 1, setting a flag (8888) for areas to ignore
  pollin_r <- fasterize::fasterize(x, raster::raster(r)) %>%
     terra::rast()

  message("Calculating distances...")
  # mask it by a buffered version so we don't give unnecessary cells to compute to the distance function
  pollin_buff <- terra::buffer(pollin_r, dist) %>%   # create buffer
     terra::classify(., matrix(c(1, NA), byrow=TRUE, ncol=2))

  #pollin_r <- terra::cover(pollin_r, pollin_buff) # now source is 1, target areas to calculate distances are NA, and value to IGNORE is 0


  pollin_dist <- terra::distance(pollin_r) %>%
     terra::mask(pollin_buff, inverse = TRUE)


  message("Distance raster created. Calculating scores...")


  # Invert the distance to create scores
  scores <- terra::app(pollin_dist, function(x){(dist - x)/dist*100})


  ### Clip to study area and save to outputs folder -----

  message("Saving final pollination demand map.")

  final <- terra::writeRaster(
    raster::mask(scores, studyArea),
    filename = file.path(save, paste(projectLog$title, runtitle, "pollination_demand.tif", sep="_")),
    overwrite = TRUE  # perhaps not desirable but for now prevents error messages
  )


  timeB <- Sys.time() # stop time

  # write performance to log
  projectLog$performance[["dem_pollin"]] <- as.numeric(difftime(
    timeB, timeA, units="mins"
  ))


  updateProjectLog(projectLog) # save revised log

  # Delete all the stuff we don't need anymore

  on.exit({
    rm(r, pollin_r, maxval)
    cleanUp(scratch)
    message("Pollination demand model finished. Process took ", round(difftime(timeB, timeA, units = "mins"), digits = 1), " minutes. Please check output folder for your maps.")
  })

  return({
    ## returns the objects in the global environment
    invisible({
      projectLog <<- projectLog
    })
  })


}
