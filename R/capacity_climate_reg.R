##########################################
### Climate regulation capacity model  ###
### for EcoservR tool                  ###
### Sandra Angers-Blondin              ###
### 18 Dec 2020                        ###
##########################################

#' Climate Regulation Capacity Model
#'
#' Runs the climate regulation ecosystem service model, generating capacity scores based on the ability of vegetation and water bodies to cool down the temperature locally.

#' @param x A basemap, in a list of sf tiles or as one sf object. Must have attribute HabCode_B.
#' @param studyArea The boundaries of the site, as one sf object. The final raster will be masked to this shape. For best results this shape should be smaller than the basemap (which should be buffered by typically 300 m - 1km to avoid edge effects).
#' @param res Desired resolution of the raster. Default is 5 m. Range recommended is 5-10m.
#' @param local Radius (m) for focal statistics at local range (maximum distance for effectiveness). Default is 300 m.
#' @param use_hedges Use a separate hedgerow layer? Default FALSE, see clean_hedgerows() for producing a model-ready hedge layer.
#' @param projectLog The RDS project log file generated by the wizard app and containing all file paths to data inputs and model parameters
#' @param runtitle A customised title you can give a specific model run, which will be appended to your project title in the outputs. If comparing a basemap to an intervention map, we recommend using "pre" and "post", or a short description of the interventions, e.g. "baseline" vs "tree planting".
#' @param save Path to folder where outputs will be saved. By default a folder will be created using your chosen run title, prefixed by "services_". Do not use this argument unless you need to save the outputs somewhere else.
#' @return Two rasters with capacity scores: one with raw scores (arbitrary units), and one rescaled 0-100 (where 100 is maximum capacity for the area).
#' @export
#'
capacity_climate_reg <- function(x = parent.frame()$mm,
                                 studyArea = parent.frame()$studyArea,
                                 res = 5,
                               local = 200,
                               use_hedges = FALSE,
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

   studyArea <- sf::st_zm(studyArea, drop=TRUE)

   x <- checkcrs(x, 27700)
   studyArea <- checkcrs(studyArea, 27700)

   ### Check and import hedgerows ----
   if (use_hedges){

      if (!file.exists(projectLog$clean_hedges)){stop("use_hedges is TRUE but no file found. Check projectLog$clean_hedges")}

      hedges <- readRDS(projectLog$clean_hedges) %>%
         dplyr::mutate(HabCode_B = 'J21') %>% dplyr::select(HabCode_B) %>%
         merge(hab_lookup[c("Ph1code", "HabClass")], by.x = 'HabCode_B', by.y = 'Ph1code', all.x = TRUE)

      message("Loaded hedges from ", projectLog$clean_hedges)
      hedges <- rename_geometry(hedges, attr(x, "sf_column"))
      hedges <- checkcrs(hedges, 27700)

   }

   ### Merge the lookup table -----

   x$HabClass <- NULL

   x <- merge(x, hab_lookup, by.x = "HabCode_B", by.y = "Ph1code", all.x = TRUE)

   x <- x[c("HabCode_B", "HabClass")] # keep only required columns


   ### Create raster template with same properties as mastermap -----

   r <- raster::raster()  # create empty raster
   raster::crs(r) <- sp::CRS(SRS_string = "EPSG:27700") # hard-coding datum to preserve CRS
   raster::extent(r) <- raster::extent(x)  # set same extent as the shapefile
   raster::res(r) <- res  # set resolution


   ### Extract greenspaces and areas with trees from the map ----
   message("Extracting basemap features with cooling capacity")

   x <- x[x$HabClass %in% c("Woodland and scrub",
                            "Water", "Green urban surfaces") | x$HabCode_B == "J21",] # make sure hedgerows can contribute to service
   # We want all woodland, scattered trees, scrub, and water

   if (use_hedges){
      x <- rbind(x, hedges)  # no need to erase, doesn't matter for the mask whether polygons overlap. Gets unioned later anyway
   }


   ### Rasterize -----

   green_r <- raster::writeRaster(
      fasterize::fasterize(x, r, background = NA),  # cells with trees get 1, rest NA
      filename = file.path(scratch, "climreg_score"),
      overwrite = TRUE
   )

   ### Focal statistics ----

   clim_score <- focalScore(green_r, radius = local, type = "sum")


   rm(green_r) # free up memory

   ### Create buffers around patches of woodland ----

   ## First, buffer the wood layer slightly (to fill gaps like paths and streams), and dissolve

   x <- x %>% sf::st_buffer(4) %>%      # buffer by 4m
      sf::st_union() %>%                # dissolve in case there's overlap
      sf::st_cast(to  ="MULTIPOLYGON") %>%
      sf::st_cast(to = "POLYGON", warn = FALSE) %>%   # multi to single polygon
      sf::st_sf() %>%                   # make sure it's in right format
      dplyr::mutate(area = as.numeric(sf::st_area(.)))     # calculate shape area


   ##  Smaller patches have less of an influence on their neighbourhood than large patches,
   #  so we apply a series of buffers whose size depends on the patch area


   message("Calculating area of influence around vegetated patches")
   b1 <- dplyr::filter(x, area <= 20000) %>% sf::st_buffer(20) %>% sf::st_union() %>% sf::st_sf()

   b2 <- dplyr::filter(x, dplyr::between(area, 20000, 50000)) %>% sf::st_buffer(40) %>% sf::st_union() %>% sf::st_sf()

   b3 <- dplyr::filter(x, dplyr::between(area, 50000, 100000)) %>% sf::st_buffer(80) %>% sf::st_union() %>% sf::st_sf()

   b4 <- dplyr::filter(x, area > 100000) %>% sf::st_buffer(100) %>% sf::st_union() %>% sf::st_sf()

   # Bind and dissolve those buffers to create the mask
   # For the bind to work there must be at least one non-empty object so checking first

   if (nrow(b1) > 0 | nrow(b2) > 0 | nrow(b3) > 0 | nrow(b4) > 0){

      mask <- rbind(b1, b2, b3, b4) %>% sf::st_union() %>% sf::st_sf()
      rm(b1,b2,b3,b4)

      mask <- checkgeometry(mask, "POLYGON")

      mask_r <- fasterize::fasterize(mask, r)  #  much quicker to work with a rasterized version

      rm(mask)

   } else{
      message("Study area does not contain climate-regulating features. If you think this is a mistake, check classification.")
      mask_r <- r  # if there are no patches at all providing service, mask is whole raster
      mask_r[] <- 1  # putting a value so that it can act as a mask
   }

   ### Apply the mask, because effect is only felt close to greenspaces ----
   message("Applying mask around regulating patches")
   clim_score <- raster::mask(clim_score, mask_r,   # apply the mask on the raster object
                      filename = file.path(scratch, "climreg_score2"),
                      overwrite = TRUE
   )

   # change NA values to 0 (otherwise holes in raster)

   clim_score <- raster::reclassify(clim_score,
                            cbind(NA, 0),  # change the NAs
                            filename = file.path(scratch, "climreg_score"),
                            overwrite = TRUE
   )

   ### Clip to study area and save final file
   message("Saving final and standardised scores.")

   final <- raster::writeRaster(
      raster::mask(clim_score, studyArea),
      filename = file.path(save,
                           paste(projectLog$title, runtitle, "climate_regulation_capacity.tif", sep="_")),
      overwrite = TRUE
   )
   rm(clim_score)

   ### Also create a standardised version

   maxval <- max(raster::values(final), na.rm = TRUE)

   final_scaled <- raster::writeRaster(
      final/maxval*100,  # rescale from 0-100
      filename = file.path(save, paste(projectLog$title, runtitle, "climate_regulation_capacity_rescaled.tif", sep="_")),
      overwrite = TRUE  # perhaps not desirable but for now prevents error messages
   )

   timeB <- Sys.time() # stop time

   # write performance to log
   projectLog$performance[["cap_clim"]] <- as.numeric(difftime(
      timeB, timeA, units="mins"
   ))


   updateProjectLog(projectLog) # save revised log


   # Delete all the stuff we don't need anymore

   on.exit({
      rm(r, final, final_scaled, maxval)
      cleanUp(scratch)
      message("Local climate regulation capacity model finished. Process took ", round(difftime(timeB, timeA, units = "mins"), digits = 1), " minutes. Please check output folder for your maps.")
   })

   return({
      ## returns the objects in the global environment
      invisible({
         projectLog <<- projectLog
      })
   })

}
