library(catR)

getSessionId = function(session) {
  id = 0
  if(!is.null(session) && is.list(session)) {
    id = session$id
  } else {
    id = paste0("i",concerto$session$id)
  }
  return(id)
}

getSafeItems = function(items, extraFields) {
  safeItems = NULL
  extraFields = fromJSON(extraFields)

  for(i in 1:dim(items)[1]) {
    item = as.list(items[i,])

    if(!is.null(item$responseOptions) && item$responseOptions != "") {
      if(is.character(item$responseOptions)) {
        item$responseOptions = tryCatch({
          fromJSON(item$responseOptions)
        }, error = function(message) {
          concerto.log(message)
          stop(paste0("item #", item$id, " contains invalid JSON in responseOptions field"))
        })
      }
      responseOptionsRandomOrder = item$responseOptions$optionsRandomOrder == "1"
      orderedOptions = c()

      if(length(item$responseOptions$options) > 0) {
        if(responseOptionsRandomOrder) {
          orderedOptions = item$responseOptions$options[sample(1:length(item$responseOptions$options))]
        } else {
          orderedOptions = item$responseOptions$options
        }
      }
      item$responseOptions$options = orderedOptions
      item$responseOptions$defaultScore = NULL
      item$responseOptions$scoreMap = NULL
      item$responseOptions = toJSON(item$responseOptions)
    }

    for(extraField in extraFields) {
      if(extraField$sensitive == 1) {
        item[[extraField$name]] = NULL
      }
    }

    safeItems = rbind(safeItems, item)
  }

  return(safeItems)
}

getSafePastResponses = function(nextItems) {
  responseBank = fromJSON(settings$responseBank)
  if(is.null(responseBank$table)) {
    concerto.log("no response bank defined")
    return(NULL)
  }

  sql = "
SELECT * FROM {{table}}
WHERE 
{{sessionIdColumn}}='{{sessionId}}' AND
{{itemIdColumn}} IN ({{itemIds}})
"
  responses = concerto.table.query(sql, list(
    table=responseBank$table,
    sessionIdColumn=responseBank$columns$session_id,
    sessionId=getSessionId(session),
    itemIdColumn=responseBank$columns$item_id,
    itemIds=paste(nextItems[,"id"], collapse=",")
  ))
  if(dim(responses)[1] > 0) {
    responses[,"score"] = NULL
    responses[,"sem"] = NULL
    responses[,"theta"] = NULL
    return(responses)
  }
  return(NULL)
}

itemsNum = dim(items)[1]
nextItemsIndices = which(items$id %in% resumedItemsIds)
itemsPerPage = as.numeric(settings$itemsPerPage)
nextPage = as.numeric(prevPage) + as.numeric(direction)

if(length(nextItemsIndices) == 0) {
  itemsExcluded = NULL
  
  if(settings$order == "cat") {
    itemsExcluded = unique(c(itemsExcluded, which(items$fixedIndex > 0)))

    #content balancing
    cbGroup = NULL
    cbControl = NULL
    cbProps = fromJSON(settings$contentBalancing)
    concerto.log(cbProps, "cbProps")
    if(length(cbProps) > 0) {
      cbGroup = as.character(items[,"trait"])
      cbControl = list(
        names=NULL,
        props=NULL
      )
      for(i in 1:length(cbProps)) {
        cbControl$names = c(cbControl$names, cbProps[[i]]$name)
        cbControl$props = c(cbControl$props, as.numeric(cbProps[[i]]$proportion))
      }
      concerto.log(cbControl, "cbControl")
    }

    for(onPageIndex in 1:itemsPerPage) {
      #fixed indices
      inTestIndex = length(itemsAdministered) + onPageIndex
      fixedItemIndex = which(items$fixedIndex == inTestIndex)[1]
      if(!is.na(fixedItemIndex)) {
        nextItemsIndices = c(nextItemsIndices, fixedItemIndex)
        next
      }

      isAnyItemLeft = itemsNum > length(itemsAdministered)
      if(isAnyItemLeft) {
        nAvailable = NULL
        for(i in 1:dim(items)[1]) {
            item = items[i,]
            available = if(!is.null(item$fixedIndex) && !is.na(item$fixedIndex) && item$fixedIndex > 0) { 
              0 
            } else { 
              1 
            }
            nAvailable = c(nAvailable, available)
        }
        randomesque = as.numeric(settings$nextItemRandomesque)

        result = tryCatch({
          nextItem(paramBank, model=settings$model, theta=theta, out=itemsAdministered, x=scores, nAvailable=nAvailable, criterion=settings$nextItemCriterion, method=settings$scoringMethod, randomesque=randomesque, cbGroup=cbGroup, cbControl=cbControl)
        }, error=function(ex) {
          concerto.log(ex, "potentialy not possible to satisfy CB rule")
          if(!is.null(cbGroup) && !is.null(cbControl)) {
            return(nextItem(paramBank, model=settings$model, theta=theta, out=itemsAdministered, x=scores, nAvailable=nAvailable, criterion=settings$nextItemCriterion, method=settings$scoringMethod, randomesque=randomesque, cbGroup=NULL, cbControl=NULL))
          } else {
            stop(ex)
          }
        })
        nextItemsIndices = c(nextItemsIndices, result$item)
        itemsExcluded = c(itemsExcluded, result$item)
      }
    }
  } else {
    #linear
    pageFirstItemIndex = (nextPage - 1) * as.numeric(settings$itemsPerPage) + 1
    pageLastItemIndex = min(nextPage * as.numeric(settings$itemsPerPage), dim(items)[1])
    nextItemsIndices = pageFirstItemIndex:pageLastItemIndex
  }

  if(!is.na(settings$nextItemModule) && settings$nextItemModule != "") {
    nextItemsIndices = concerto.test.run(settings$nextItemModule, params=list(
      nextItemsIndices=nextItemsIndices,
      settings = settings,
      theta = theta,
      itemsAdministered=itemsAdministered,
      itemsExcluded=itemsExcluded,
      cbGroup=cbGroup,
      cbControl=cbControl,
      session=session,
      items=items
    ))$nextItemsIndices
  }
}

concerto.log(nextItemsIndices, "nextItemsIndices")
nextItems = items[nextItemsIndices,]
concerto.log(nextItems, "next items")
nextItemsSafe = getSafeItems(nextItems, settings$itemBankTableExtraFields)
responsesSafe = getSafePastResponses(nextItems)
resumedItemsIds = NULL