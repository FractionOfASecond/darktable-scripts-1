dt = require "darktable"
table = require "table"

local function getImagePath(i) return "'"..i.path.."/"..i.filename.."'" end

local function write_geotag()
  local images_to_write = {}
  local image_table = dt.gui.selection()
  local precheck_fraction = 0.2
  local image_table_count = 0
  local tagged_files_skipped = 0
  
  save_job = dt.gui.create_job ("Saving exif geotags", true)
  
  for _,image in pairs(image_table) do
    if (image.longitude and image.latitude) then
      local includeImage = true
      if (not dt.preferences.read("write_geotag","OverwriteGeotag","bool")) then
        local exifReadProcess = io.popen("exiftool -n -GPS:All "..getImagePath(image))
        local exifLine = exifReadProcess:read()
        while exifLine do
          if (exifLine ~= '') then
            local gpsTag, gpsValue = string.match(exifLine, "(GPS %a+)%s+: ([%d%.]+)")
            includeImage = false
          end
          exifLine = exifReadProcess:read()
        end
        exifReadProcess:close()
        
        if (not includeImage) then
          tagged_files_skipped = tagged_files_skipped + 1
        end
      end
      
      
      if includeImage then
        table.insert(images_to_write,image)
        image_table_count = image_table_count + 1
      end
    end
  end
  
  save_job.percent = precheck_fraction
  
  local image_done_count = 0
  
  for _,image in pairs(images_to_write) do
    local exifCommand = "exiftool"
    if (dt.preferences.read("write_geotag","DeleteOriginal","bool")) then
      exifCommand = exifCommand.." -overwrite_original"
    end
    if (dt.preferences.read("write_geotag","KeepFileDate","bool")) then
      exifCommand = exifCommand.." -preserve"
    end
    
    local imagePath = getImagePath(image)
    
    exifCommand = exifCommand.." -exif:GPSLatitude="..image.latitude.." -exif:GPSLatitudeRef="..image.latitude.." -exif:GPSLongitude="..image.longitude.." -exif:GPSLongitudeRef="..image.longitude.." -exif:GPSAltitude= -exif:GPSAltitudeRef= -exif:GPSHPositioningError= "..imagePath
    
    local testIsFileCommand = "test -f "..imagePath
    
    --Will fail and exit if image file does not exist (or path is invalid)
    coroutine.yield("RUN_COMMAND", testIsFileCommand)
    
    coroutine.yield("RUN_COMMAND", exifCommand)
    
    image_done_count = image_done_count + 1
    save_job.percent = (image_done_count/image_table_count)*(1-precheck_fraction) + precheck_fraction
    
  end
  
  save_job.valid = false
  
  if (tagged_files_skipped > 0) then
    dt.print(tagged_files_skipped.." image(s) were skipped as they already had a EXIF geotag")
  end
end

dt.preferences.register("write_geotag", "OverwriteGeotag", "bool", "Write geotag: allow overwriting existing file geotag", "Replace existing geotag in file. If unchecked, files with lat & lon data will be silently skipped.", false )
dt.preferences.register("write_geotag", "DeleteOriginal", "bool", "Write geotag: delete original image file", "Delete original image file after updating EXIF. When off, keep it in the same folder, appending _original to its name", false )
dt.preferences.register("write_geotag", "KeepFileDate", "bool", "Write geotag: carry over original image file's creation & modification date", "Sets same creation & modification date as original file when writing EXIF. When off, time and date will be that at time of writing new file, to reflect that it was altered. Camera EXIF date and time code are never altered, regardless of this setting.", true )

dt.register_event("shortcut",write_geotag, "Write geotag to image file")
