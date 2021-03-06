##******************************************************
##
##  MirtarbaseDb class methods
##
##******************************************************
##
##     public methods
##***********************************************************************
setMethod("dbconn", "MirtarbaseDb", function(x){
    con <- x@con
    return(con)
})

setMethod("listColumns", "MirtarbaseDb", function(x, table, skip.keys=TRUE, ...){
    if(length(x@tables)==0){
        tables <- dbListTables(x@con)
        ## read the attributes for these tables.
        Tables <- vector(length=length(tables), "list")
        for(i in 1:length(Tables)){
            Tables[[ i ]] <- colnames(dbGetQuery(x@con, paste0("select * from ",
                                                               tables[ i ], " limit 1")))
        }
        names(Tables) <- tables
        x@tables <- Tables
    }
    if(!missing(table)){
        columns <- x@tables[[ table ]]
    }else{
        columns <- unlist(x@tables, use.names=FALSE)
    }
    if(skip.keys){
        ## remove everything that has a _pk or _fk...
        idx <- grep(columns, pattern="_fk$")
        if(length(idx) > 0)
            columns <- columns[ -idx ]
        idx <- grep(columns, pattern="_pk$")
        if(length(idx) > 0)
            columns <- columns[ -idx ]
    }
    return(columns)
})

setMethod("metadata", "MirtarbaseDb", function(x, ...){
    return(dbGetQuery(dbconn(x), "select * from metadata;"))
})

setMethod("listExperiments", "MirtarbaseDb", function(x, ...){
    Exps <- dbGetQuery(x@con, "select distinct experiments from mirtarbase;")[ , 1 ]
    Exps <- unique(unlist(strsplit(Exps, split="//")))
    return(Exps)
})

setMethod("listPmids", "MirtarbaseDb", function(x, ...){
    pmids <- dbGetQuery(x@con, "select distinct references_pmid from mirtarbase;")[ , 1]
    return(pmids)
})

setMethod("listSpecies", "MirtarbaseDb", function(x, of="gene", ...){
    of <- match.arg(of, c("gene", "mirna"))
    if(of=="gene"){
        Species <- x@species_target_gene
        if(length(Species)==0){
            Species <- dbGetQuery(x@con, paste0("select distinct species_target_gene",
                                                " from mirtarbase;"))[ , 1 ]
        }
    }
    if(of=="mirna"){
        Species <- x@species_mirna
        if(length(Species)==0){
            Species <- dbGetQuery(x@con, paste0("select distinct species_mirna",
                                                " from mirtarbase;"))[ , 1 ]
        }
    }
    return(Species)
})

setMethod("listSupportTypes", "MirtarbaseDb", function(x, ...){
    ST <- x@support_type
    if(length(ST)==0){
        ST <- dbGetQuery(x@con, "select distinct support_type from mirtarbase;")[ , 1 ]
    }
    return(ST)
})

setMethod("show", "MirtarbaseDb", function(object){
    cat("MirtarbaseDb:\n")
    md <- metadata(object)
    cat(paste0("| miRTarbase version: ", md[md[, 1] == "version", 2], "\n"))
    cat(paste0("| miRTarbase date: ", md[md[, 1] == "release date", 2], "\n"))
    con <- object@con
    ## number of MTIs:
    mtis <- dbGetQuery(con, "select count(distinct mirtarbase_id) from mirtarbase;")[1, 1]
    cat(paste0("| Number of MTIs: ", mtis ,"\n"))
    miRNAs <- dbGetQuery(con, "select count(distinct mirna) from mirtarbase;")[1, 1]
    cat(paste0("| Number of miRNAs: ", miRNAs, "\n"))
    ## number of genes:
    genes <- dbGetQuery(con, "select count(distinct target_gene) from mirtarbase;")[1, 1]
    cat(paste0("| Number of target genes: ", genes, "\n"))
    cat("| Number of MTIs grouped by support type:\n")
    ## MTI evidences:
    Tab <- dbGetQuery(con, paste0("select support_type, count(*) as number_MTI",
                                  " from mirtarbase group by support_type"))
    for(i in 1:nrow(Tab)){
        cat(paste0("| * ", Tab[ i, 1 ], ": ", Tab[ i, 2 ],"\n"))
    }
})

setMethod("listTables", "MirtarbaseDb", function(x, ...){
    if(length(x@tables)==0){
        tables <- dbListTables(x@con)
        ## read the attributes for these tables.
        Tables <- vector(length=length(tables), "list")
        for(i in 1:length(Tables)){
            Tables[[ i ]] <- colnames(dbGetQuery(x@con, paste0("select * from ",
                                                               tables[ i ], " limit 1")))
        }
        names(Tables) <- tables
        x@tables <- Tables
    }
    Tab <- x@tables
    return(Tab)
})

setMethod("version", "MirtarbaseDb", function(object, ...){
    return(object@mirtarbase_version)
})

####============================================================
##  listMirtarbaseReleases
##
##  function to list all releases provided by the mirtarbase package
####------------------------------------------------------------
listMirtarbaseReleases <- function(){
    path <- system.file("extdata", package="mirtarbase")
    files <- dir(path, pattern="sqlite")
    files <- gsub(files, pattern=".sqlite", replacement="", fixed=TRUE)
    versions <- gsub(files, pattern="Mirtarbase.v", replacement="")
    idx <- order(versions, decreasing=TRUE)
    Res <- data.frame(variable=files, release=versions, stringsAsFactors=FALSE)
    return(Res[idx, ])
}

##******************************************************
##
##  The /real/ functionality
##
##  + mtis: retrieve miRNA target gene interactions based
##          on the filters; returns either a data.frame or
##          a list of MTI objects (default).
##  + mtisBy: retrieve MTIs by either miRNA or gene.
##
##  the tricky thing with the above methods is that we want
##  to allow also MirfamFilter and PremirnaFilter. For these
##  we have to map first the mirfam or pre-miRNA IDs to
##  mature miRNA names.
##******************************************************
setMethod("mtis", "MirtarbaseDb", function(x, columns=listColumns(x, "mirtarbase"),
                                           filter, order.by="mirtarbase_id",
                                           order.type="asc", return.type="MTIList",
                                           force=FALSE){
    return.type <- match.arg(return.type, c("MTIList", "data.frame"))
    filter <- .checkFilter(filter)
    ## check if the attributes are correct:
    torem <- !(columns %in% listColumns(x, "mirtarbase"))
    if(any(torem)){
        warning(paste0("Columns ", paste(columns[ torem ], collapse=", "),
                       " are not valid and have been removed." ))
        columns <- columns[ !torem ]
    }
    if(length(columns)==0){
        stop("No columns submitted!")
    }
    ## if we're going to return a MTI object we need all attributes:
    if(return.type=="MTIList"){
        gotCols <- columns
        columns <- listColumns(x, "mirtarbase")
        if(!all(columns %in% gotCols))
            warning("Specifying 'columns' with 'return.type' set to \"MTIList\"",
                    " is not possible.")
    }
    ## check that the order.by is in the columns, if not, drop it
    if(!any(columns == order.by))
        order.by <- ""
    ## Note values from e.g. PremirnaFilter are automatically mapped to
    ## mature miRNA ids in the respetive where method.
    Res <- .getWhat(x, columns=columns, filter=filter, order.by=order.by,
                    order.type=order.type, match.case=FALSE, force=force)
    if(return.type=="data.frame"){
        return(Res)
    }else{
        return(data.frame2mtiNreport(Res))
    }
})

.checkFilter <- function(filter){
    if(missing(filter))
        return(list())
    if(is(filter, "list")){
        isAFilter <- unlist(lapply(filter, function(z){
            return(is(z, "AnnotationFilter"))
        }))
        if(!all(isAFilter))
            stop("Argument 'filter' has to be a single 'AnnotationFilter'",
                 " object or a list of such objects!")
        return(filter)
    }else{
        if(is(filter, "AnnotationFilter")){
            return(list(filter))
        }else{
            stop("Argument 'filter' has to be a single 'AnnotationFilter' ",
                 "object or a list of such objects!")
        }
    }
}

## return mtis by some selected attribute:
setMethod("mtisBy", "MirtarbaseDb", function(x, by="gene", filter){
    by <- match.arg(by, c("gene", "matmirna", "entrezid", "pmid",
                          "support_type", "premirna", "mirfam", "species_gene",
                          "species_mirna"))
    ## split by what.
    filter <- .checkFilter(filter)
    split.by <- "target_gene"
    if(by=="matmirna")
        split.by <- "mirna"
    if(by=="entrezid")
        split.by <- "target_gene_entrez_id"
    if(by=="pmid")
        split.by <- "references_pmid"
    if(by=="support_type")
        split.by <- "support_type"
    if(by=="species_gene")
        split.by <- "species_target_gene"
    if(by=="species_mirna")
        split.by <- "species_mirna"
    Res <- .getWhat(x, columns=listColumns(x, "mirtarbase"), filter=filter,
                    order.by="mirtarbase_id")
    ## split here, and run data.frame2mtiNreport on the list...
    if(by %in% c("mirfam", "premirna")){
        ## if we've got premirna or mirfam we've got to map those.
        if(by=="mirfam"){
            mirfams <- matmirna2mirfam(Res[ , "mirna" ])
            ## replace NAs with "other"
            mirfams[ is.na(mirfams[ , 2]), 2 ] <- "other"
            MTIsby <- lapply(split(Res, mirfams[ , 2 ]), data.frame2mtiNreport)
        }
        ## premirna is a little tricky; the mapping can be n:m, thus we have to
        ## duplicate rows of the data.frame if e.g. a mature miRNA is encoded in
        ## more than one pre-miRNA.
        if(by=="premirna"){
            applyfun <- lapply
            ## can not use mclapply on a database connection...
            ## if(nrow(Res) > 100){
            ##     applyfun <- mclapply
            ## }
            ## do a crazy split lapply rbind... so basically, run the code for each row.
            suppressWarnings(
                tmp <- do.call(rbind, applyfun(split(Res, 1:nrow(Res)),
                                               FUN=function(z){
                                                   pres <- matmirna2premirna(z$mirna)[, 2]
                                                   pres[ is.na(pres) ] <- "unknown"
                                                   return(data.frame(premirna=pres, z,
                                                                     check.names=FALSE))
                                               }))
            )
            MTIsby <- lapply(split(tmp, tmp$premirna), data.frame2mtiNreport)
        }

    }else{
        MTIsby <- lapply(split(Res, Res[ , split.by ]), data.frame2mtiNreport)
    }
    return(MTIsby)
})


##******************************************************
##
##  MTI class methods
##
##******************************************************
## check validity of MTI instances.
## validateMTI <- function(object){
##     ## check if the objects in the slot report are of the type Report
##     if(length(object@report) > 0){
##         Classes <- unique(unlist(lapply(object@report, class)))
##         if(any(Classes != "Report")){
##             return(paste0("Slot \"report\" should contain only \"Report\" objects! I found ", paste(Classes, collapse=","), "!"))
##         }
##     }
##     return(TRUE)
## }
## setValidity("MTI", validateMTI)
## setMethod("initialize", "MTI", function(.Object,...){
##     OK <- validateMTI(.Object)
##     if(class(OK)=="character"){
##         stop(OK)
##     }
##     callNextMethod(.Object, ...)
## })

setMethod("show", "MTI", function(object){
    cat(paste0("ID: ", id(object), "\n"))
    cat(paste0("mature miRNA: ", matmirna(object), "\n"))
    cat(paste0("miRNA species: ", mirnaSpecies(object), "\n"))
    cat(paste0("target gene: ", gene(object), "\n"))
    cat(paste0("target gene entrezid: ", entrezid(object), "\n"))
    cat(paste0("target gene species: ", geneSpecies(object), "\n"))
    cat(paste0("Number of supporting reports: ", reportCount(object), "\n"))
    cat("Reports:\n")
    lapply(reports(object), show)
})

setMethod("shortShow", "MTI", function(object){
    cat(paste0(id(object), ": ", matmirna(object), "\t-|\t", gene(object), "\t(",
               reportCount(object), ")\n"))
})

## setter for report.
setMethod("reports<-", signature(object="MTI", value="MTIReport"), function(object, value){
    value <- list(value)
    names(value) <- unlist(lapply(value, pmid))
    object@report <- value
    object
})

setMethod("reports<-", signature(object="MTI", value="list"), function(object, value){
    isReport <- unlist(lapply(value, function(z){
        return(is(z, "MTIReport"))
    }))
    if(!all(isReport))
        stop("value has to be either a single MTIReport class or a list of MTIReport classes")
    ## setting the names of the list
    names(value) <- unlist(lapply(value, pmid))
    object@report <- value
    object
})


##****************************************************
##
##   accessors
##
##****************************************************
setMethod("entrezid", "MTI",
          function(object, ...){
              return(object@target_gene_entrezid)
          })
setMethod("experiments", "MTI",
          function(object, ...){
              return(unlist(lapply(reports(object), experiments), use.names=FALSE))
          })
setMethod("gene", "MTI",
          function(object, ...){
              return(object@target_gene)
          })
setMethod("geneSpecies", "MTI",
          function(object, ...){
              return(object@species_target_gene)
          })
setMethod("id", "MTI",
          function(object, ...){
              return(object@id)
          })
setMethod("matmirna", "MTI",
          function(object, ...){
              return(object@mature_mirna)
          })
setMethod("mirnaSpecies", "MTI",
          function(object, ...){
              return(object@species_mirna)
          })
setMethod("pmid", "MTI",
          function(object, ...){
              return(unlist(lapply(reports(object), pmid), use.names=FALSE))
          })
setMethod("reportCount", "MTI",
          function(object, ...){
              reps <- reports(object)
              return(length(reps))
          })
setMethod("reports", "MTI",
          function(x, ...){
              if(length(x@report)==0){
                  return(list(MTIReport()))
              }
              return(x@report)
          }
          )
setMethod("supportedBy", "MTI",
          function(object, ...){
              return(unlist(lapply(reports(object), supportedBy), use.names=FALSE))
          })
## methods that convert mature miRNA ids to pre-miRNA, mirfam etc ids
## Note: this will only work well if the mirbase version from mirtarbase
## is the same as the mirbase version from the mirbase package.
setMethod("premirna", "MTI",
          function(object, ...){
              tmp <- matmirna2premirna(matmirna(object))
              if(is.null(tmp))
                  return(tmp)
              return(tmp[ , 2 ])
          })
setMethod("mirfam", "MTI",
          function(object, ...){
              tmp <- matmirna2mirfam(matmirna(object))
              if(is.null(tmp))
                  return(tmp)
              return(tmp[ , 2 ])
          })
setMethod("premirnaId", "MTI",
          function(object){
              tmp <- matmirna2premirnaAcc(matmirna(object))
              if(is.null(tmp))
                  return(tmp)
              return(tmp[ , 2 ])
          })
setMethod("matmirnaId", "MTI",
          function(object){
              tmp <- matmirna2matmirnaAcc(matmirna(object))
              if(is.null(tmp))
                  return(tmp)
              return(tmp[ , 2 ])
          })
## setMethod("matmirnaSequence", "MTI",
##           function(object, ...){
##               tmp <- getMirbaseForMature(matureMirna(object))
##               matseq <- apply(tmp, MARGIN=1, function(z){
##                   return(substr(z[ "sequence" ], start=as.numeric(z[ "mature_from" ]), stop=as.numeric(z[ "mature_to" ])))
##               })
##               return(unique(matseq))
##           })

setMethod("as.data.frame", "MTI",
          function(x, collapse.reports=NULL,
                   stringsAsFactors=getOption("stringsAsFactors", TRUE), ...){
              df <- mti2data.frame(x, collapse.reports=collapse.reports,
                                   stringsAsFactors=stringsAsFactors)
              if(is.null(collapse.reports)){
                  rownames(df) <- NULL
              }else{
                  rownames(df) <- id(x)
              }
              return(df)
          })

##******************************************************
##
##  MTIList class methods
##
##******************************************************
setMethod("show", "MTIList", function(object){
    cat(paste0("MTIList of length ", length(object), "\n"))
    cat(paste0(" <MTI ID> : <miRNA>\t\t-|\t<gene>\t(<report count>)\n"))
    if(length(object) <= 6){
        lapply(object, shortShow)
    }
    else{
        ## show the first 3 and last 3.
        lapply(head(object, n=3), shortShow)
        cat("    ...                   ...\n")
        cat("    ...                   ...\n")
        lapply(tail(object, n=3), shortShow)
    }
})
## as.data.frame
setMethod("as.data.frame", "MTIList",
          function(x, collapse.reports=NULL,
                   stringsAsFactors=getOption("stringsAsFactors", TRUE), ...){
              tmp <- do.call(rbind, lapply(x, as.data.frame,
                                           collapse.reports=collapse.reports,
                                           stringsAsFactors=stringsAsFactors))
              if(is.null(collapse.reports))
                  rownames(tmp) <- NULL
              return(tmp)
          })
## entrezid: returns characted vector
setMethod("entrezid", "MTIList", function(object, ...){
    return(unlist(lapply(object, entrezid)))
})
## experiments: returns list
setMethod("experiments", "MTIList", function(object, ...){
    return(lapply(object, experiments))
})
## gene: returns character vector
setMethod("gene", "MTIList", function(object, ...){
    return(unlist(lapply(object, gene)))
})
## geneSpecies: returns character vector
setMethod("geneSpecies", "MTIList", function(object, ...){
    return(unlist(lapply(object, geneSpecies)))
})
## id: returns character vector
setMethod("id", "MTIList", function(object, ...){
    return(unlist(lapply(object, id)))
})
## matmirna: returns character vector
setMethod("matmirna", "MTIList", function(object, ...){
    return(unlist(lapply(object, matmirna)))
})
## mirnaSpecies: returns character vector
setMethod("mirnaSpecies", "MTIList", function(object, ...){
    return(unlist(lapply(object, mirnaSpecies)))
})
## pmid: returns list
setMethod("pmid", "MTIList", function(object, ...){
    return(lapply(object, pmid))
})
## supportedBy: returns list
setMethod("supportedBy", "MTIList", function(object, ...){
    return(lapply(object, supportedBy))
})
## premirna: returns list
setMethod("premirna", "MTIList", function(object, ...){
    return(lapply(object, premirna))
})
## reportCount: returns integer vector
setMethod("reportCount", "MTIList", function(object, ...){
    return(unlist(lapply(object, reportCount)))
})
## mirfam: returns character vector
setMethod("mirfam", "MTIList", function(object, ...){
    return(unlist(lapply(object, mirfam)))
})


##******************************************************
##
##  Report class methods
##
##******************************************************
setMethod("show", "MTIReport", function(object){
    cat(paste0("PMID: ", pmid(object), "\n"))
    cat(paste0("Support type: ", supportedBy(object), "\n"))
    cat(paste0("Experiments: ", paste(experiments(object), collapse=", "), "\n"))
})
## these are the getter methods:
## slot: pmid
setMethod("pmid", "MTIReport", function(object, ...){
    return(object@pmid)
})
## slot experiments
setMethod("experiments", "MTIReport", function(object, ...){
    return(object@experiments)
})
## slot support_type
setMethod("supportedBy", "MTIReport", function(object, ...){
    return(object@support_type)
})
## cast a Report object into a data.frame
setMethod("as.data.frame", "MTIReport",
          function(x,
                   stringsAsFactors=getOption("stringsAsFactors", TRUE), ...){
              return(report2data.frame(x, row.names=pmid(x),
                                       stringsAsFactors=stringsAsFactors))
})


##***********************************************************************
##
##     Filter classes:
##
## setMethod("where", signature(object="AnnotationFilter", db="MirtarbaseDb",
##                              with.tables="missing"),
##           function(object, db, with.tables, ...){
##               ## just call the plain method without database.
##               .where(object)
##           })
## setMethod("where", signature(object="AnnotationFilter", db="MirtarbaseDb",
##                              with.tables="character"),
##           function(object, db, with.tables, ...){
##               ## just call the plain method without database.
##               .where(object)
##           })
## setMethod("where", signature(object = "AnnotationFilter", db = "missing",
##                              with.tables = "missing"),
##           function(object, db, with.tabbles, ...) {
##               .where(object)
##           })
## setMethod("column", signature(object = "AnnotationFilter", db = "missing",
##                               with.tables = "missing"),
##           function(object, db, with.tables, ...){
##               field(object)
##           })

.where <- function(x) {
    ## field condition value
    paste0(.condition(x), .value(x))
}
.condition <- function(x) {
    cond <- condition(x)
    if (length(unique(value(x))) > 1) {
        if (cond == "==")
            cond <- "in "
        if (cond == "!=")
            cond <- "not in "
    }
    if (cond == "==")
        cond <- "="
    if (cond %in% c("startsWith", "endsWith", "contains"))
        cond <- "like "
    cond    
}
.value <- function(x) {
    vals <- unique(value(x))
    if (is(x, "CharacterFilter")) {
        vals <- sQuote(gsub(unique(vals), pattern = "'", replacement = "''"))
    }
    if (length(vals) > 1)
        vals <- paste0("(",  paste0(vals, collapse = ","), ")")
    ## Process the like/startsWith/endsWith
    if (condition(x) == "startsWith")
        vals <- paste0("'", unique(x@value), "%'")
    if (condition(x) == "endsWith")
        vals <- paste0("'%", unique(x@value), "'")
    if (condition(x) == "contains")
        vals <- paste0("'%", unique(x@value), "%'")
    vals
}


##***********************************************************************
##
##     ExperimentFilter
##
##***********************************************************************
## plain and simple; do have only a single table.
.requireTable <- function(attr, db){
    return("mirtarbase")
}
setMethod("requireTable", signature(x="ExperimentFilter", db="MirtarbaseDb"),
          function(x, db, ...){
              return(.requireTable("experiments" , db))
          })
setMethod("column", signature(object="ExperimentFilter", db="MirtarbaseDb"),
          function(object, db, ...){
              return("experiments")
          })
setMethod("where", signature(object="ExperimentFilter", db="MirtarbaseDb"),
          function(object, db, ...){
              paste(column(object, db), .where(object))
          })

##***********************************************************************
##
##     PublicationFilter
##
##***********************************************************************
setMethod("requireTable", signature(x="PublicationFilter", db="MirtarbaseDb"),
          function(x, db, ...){
              return(.requireTable("references_pmid" , db))
          })
setMethod("column", signature(object="PublicationFilter", db="MirtarbaseDb"),
          function(object, db, ...){
              return("references_pmid")
          })
setMethod("where", signature(object="PublicationFilter", db="MirtarbaseDb"),
          function(object, db, ...){
              paste(column(object, db), .where(object))
          })

##***********************************************************************
##
##     SpeciesFilter
##
##***********************************************************************
setMethod("requireTable", signature(x="SpeciesFilter", db="MirtarbaseDb"),
          function(x, db, ...){
              return(.requireTable("species_target_gene" , db))
          })
setMethod("column", signature(object="SpeciesFilter", db="MirtarbaseDb"),
          function(object, db, ...){
              if(!any(c("gene", "mirna") == object@feature))
                  stop("Parameter \"feature\" of SpeciesFilter should be",
                       " either \"gene\" or \"mirna\"!")
              if(object@feature=="gene")
                  return("species_target_gene")
              if(object@feature=="mirna")
                  return("species_mirna")
          })
setMethod("where", signature(object="SpeciesFilter", db="MirtarbaseDb"),
          function(object, db, ...){
              if(!any(c("gene", "mirna") == object@feature))
                  stop("Parameter \"feature\" of SpeciesFilter should be",
                       " either \"gene\" or \"mirna\"!")
              allspecies <- unique(c(listSpecies(db, "gene"), listSpecies(db, "mirna")))
              Vals <- object@value
              ## Replace all "_" with " "
              Vals <- gsub(Vals, pattern="_", replacement=" ", fixed=TRUE)
              notthere <- Vals[ !(Vals %in% allspecies) ]
              object@value <- Vals
              if(length(notthere) > 0){
                  warning("Species \"", paste(notthere, collapse=","),"\" ",
                          "not known to the database! Use the listSpecies function",
                          " to get all supported species names.")
              }
              paste(column(object, db), .where(object))
          })
setMethod("show", "SpeciesFilter", function(object){
    callNextMethod()
    cat(paste0("| feature: ", object@feature, "\n"))
})
##***********************************************************************
##
##     SupportTypeFilter
##
##***********************************************************************
setMethod("requireTable", signature(x="SupportTypeFilter", db="MirtarbaseDb"),
          function(x, db, ...){
              return(.requireTable("support_type" , db))
          })
setMethod("column", signature(object="SupportTypeFilter", db="MirtarbaseDb"),
          function(object, db, ...){
              return("support_type")
          })
setMethod("where", signature(object="SupportTypeFilter", db="MirtarbaseDb"),
          function(object, db, ...){
              if(!any(listSupportTypes(db)==object@value)){
                  warning("Support type \"", object@value,"\" not known to",
                          " the database! Use the listSupportTypes function",
                          " to get all support types.")
              }
              paste(column(object, db), .where(object))
          })

##***********************************************************************
##
##     Implementations for GenenameFilter.
##
##     overwriting/implementation of methods for GenenameFilter defined
##     in ensembldb
##
##***********************************************************************
setMethod("requireTable", signature(x="GenenameFilter", db="MirtarbaseDb"),
          function(x, db, ...){
              return(.requireTable("target_gene" , db))
          })
setMethod("column", signature(object="GenenameFilter", db="MirtarbaseDb"),
          function(object, db, ...){
              return("target_gene")
          })
setMethod("where", signature(object = "GenenameFilter", db = "MirtarbaseDb"),
          function(object, db, ...){
              paste(column(object, db), .where(object))
          })


##***********************************************************************
##
##     Implementations for EntrezidFilter.
##
##     overwriting/implementation of methods for GenenameFilter defined
##     in ensembldb
##
##***********************************************************************
setMethod("requireTable", signature(x="EntrezFilter", db="MirtarbaseDb"),
          function(x, db, ...){
              return(.requireTable("target_gene_entrez_gene_id" , db))
          })
setMethod("column", signature(object="EntrezFilter", db="MirtarbaseDb"),
          function(object, db, ...){
              return("target_gene_entrez_gene_id")
          })
setMethod("where", signature(object="EntrezFilter", db="MirtarbaseDb"),
          function(object, db, ...){
              paste(column(object, db), .where(object))
          })


##***********************************************************************
##
##     Implementations for MatmirnaFilter.
##
##     overwriting/implementation of methods for GenenameFilter defined
##     in mirnahostgenes
##
##***********************************************************************
setMethod("requireTable", signature(x="MatMirnaFilter", db="MirtarbaseDb"),
          function(x, db, ...){
              return(.requireTable("mirna" , db))
          })
setMethod("column", signature(object="MatMirnaFilter", db="MirtarbaseDb"),
          function(object, db, ...){
              return("mirna")
          })
setMethod("where", signature(object="MatMirnaFilter", db="MirtarbaseDb"),
          function(object, db, ...){
              paste(column(object, db), .where(object))
          })

##***********************************************************************
##
##     Implementations for MirtarbaseidFilter.
##
##     overwriting/implementation of methods for BasicFilter defined
##     in ensembldb
##
##***********************************************************************
setMethod("requireTable", signature(x="MirtarbaseIdFilter", db="MirtarbaseDb"),
          function(x, db, ...){
              return(.requireTable("mirtarbase_id" , db))
          })
setMethod("column", signature(object="MirtarbaseIdFilter", db="MirtarbaseDb"),
          function(object, db, ...){
              return("mirtarbase_id")
          })
setMethod("where", signature(object="MirtarbaseIdFilter", db="MirtarbaseDb"),
          function(object, db, ...){
              paste(column(object, db), .where(object))
          })

##***********************************************************************
##
##     Implementations for PremirnaFilter.
##
##     The mirtarbase database does not contain any pre-miRNAs, thus we're
##     using the mirtarbase for the mapping.
##
##***********************************************************************
setMethod("requireTable", signature(x="PreMirnaFilter", db="MirtarbaseDb"),
          function(x, db, ...){
              return(.requireTable("premirna", db))
          })
setMethod("column", signature(object="PreMirnaFilter", db="MirtarbaseDb"),
          function(object, db, ...){
              return("mirna")
          })
setMethod("where", signature(object="PreMirnaFilter", db="MirtarbaseDb"),
          function(object, db, ...){
              ## Now I've got to map the pre-miRNA name to mature miRNA name(s)
              Mats <- premirna2matmirna(object@value)
              NAs <- is.na(Mats[ , 2 ])
              ## show a warning if the ID was not found!
              if(any(NAs))
                  warning(paste0("pre-miRNA(s) ",
                                 paste(Mats[ NAs, 1 ], collapse=", "),
                                 " not found in mirbase version ",
                                 mirbase.version(), "."))
              Matmirnas <- Mats[ !NAs, 2 ]
              ## return nothing if no miRNA left...
              if(length(Matmirnas)==0)
                  return(NULL)
              object@value <- Matmirnas
              paste(column(object, db), .where(object))
          })

##***********************************************************************
##
##     Implementations for PremirnaidFilter.
##
##     The mirtarbase database does not contain any pre-miRNAs, thus we're
##     using the mirtarbase for the mapping.
##
##***********************************************************************
setMethod("requireTable", signature(x="PreMirnaIdFilter", db="MirtarbaseDb"),
          function(x, db, ...){
              return(.requireTable("premirna_id", db))
          })
setMethod("column", signature(object="PreMirnaIdFilter", db="MirtarbaseDb"),
          function(object, db, ...){
              return("mirna")
          })
setMethod("where", signature(object="PreMirnaIdFilter", db="MirtarbaseDb"),
          function(object, db, ...){
              ## Now I've got to map the pre-miRNA accessions to mature miRNA name(s)
              Mats <- premirnaAcc2matmirna(object@value)
              NAs <- is.na(Mats[ , 2 ])
              ## show a warning if the ID was not found!
              if(any(NAs))
                  warning(paste0("pre-miRNA(s) ",
                                 paste(Mats[ NAs, 1 ], collapse=", "),
                                 " not found in mirbase version ",
                                 mirbase.version(), "."))
              Matmirnas <- Mats[ !NAs, 2 ]
              ## return nothing if no miRNA left...
              if(length(Matmirnas)==0)
                  return(NULL)
              object@value <- Matmirnas
              paste(column(object, db), .where(object))
          })


##***********************************************************************
##
##     Implementations for MatmirnaidFilter.
##
##     The mirtarbase database does not contain any mature miRNAs accession IDs, thus we're
##     using the mirtarbase for the mapping.
##
##***********************************************************************
setMethod("requireTable", signature(x="MatMirnaIdFilter", db="MirtarbaseDb"),
          function(x, db, ...){
              return(.requireTable("matmirna_id", db))
          })
setMethod("column", signature(object="MatMirnaIdFilter", db="MirtarbaseDb"),
          function(object, db, ...){
              return("mirna")
          })
setMethod("where", signature(object="MatMirnaIdFilter", db="MirtarbaseDb"),
          function(object, db, ...){
              ## Now I've got to map the mature miRNA accessions to mature
              ## miRNA name(s)
              Mats <- matmirnaAcc2matmirna(object@value)
              NAs <- is.na(Mats[ , 2 ])
              ## show a warning if the ID was not found!
              if(any(NAs))
                  warning(paste0("mature miRNA accession(s) ",
                                 paste(Mats[ NAs, 1 ], collapse=", "),
                                 " not found in mirbase version ",
                                 mirbase.version(), "."))
              Matmirnas <- Mats[ !NAs, 2 ]
              ## return nothing if no miRNA left...
              if(length(Matmirnas)==0)
                  return(NULL)
              object@value <- Matmirnas
              paste(column(object, db), .where(object))
          })


##***********************************************************************
##
##     Implementations for MirfamFilter.
##
##     The mirtarbase database does not contain mirfam information, thus we're
##     using the mirtarbase for the mapping.
##
##***********************************************************************
setMethod("requireTable", signature(x="MirfamFilter", db="MirtarbaseDb"),
          function(x, db, ...){
              return(.requireTable("mirfam_name", db))
          })
setMethod("column", signature(object="MirfamFilter", db="MirtarbaseDb"),
          function(object, db, ...){
              return("mirna")
          })
setMethod("where", signature(object="MirfamFilter", db="MirtarbaseDb"),
          function(object, db, ...){
              ## Now I've got to map the mature miRNA accessions to mature
              ## miRNA name(s)
              Mats <- mirfam2matmirna(object@value)
              NAs <- is.na(Mats[ , 2 ])
              ## show a warning if the ID was not found!
              if(any(NAs))
                  warning(paste0("mirfam name(s) ",
                                 paste(Mats[ NAs, 1 ], collapse=", "),
                                 " not found in mirbase version ",
                                 mirbase.version(), "."))
              Matmirnas <- Mats[ !NAs, 2 ]
              ## return nothing if no miRNA left...
              if(length(Matmirnas)==0)
                  return(NULL)
              object@value <- Matmirnas
              paste(column(object, db), .where(object))
          })


##***********************************************************************
##
##     Implementations for MirfamidFilter.
##
##     The mirtarbase database does not contain mirfam information, thus we're
##     using the mirtarbase for the mapping.
##
##***********************************************************************
setMethod("requireTable", signature(x="MirfamIdFilter", db="MirtarbaseDb"),
          function(x, db, ...){
              return(.requireTable("mirfam_name", db))
          })
setMethod("column", signature(object="MirfamIdFilter", db="MirtarbaseDb"),
          function(object, db, ...){
              return("mirna")
          })
setMethod("where", signature(object="MirfamIdFilter", db="MirtarbaseDb"),
          function(object, db, ...){
              ## Now I've got to map the mature miRNA accessions to mature
              ## miRNA name(s)
              Mats <- mirfamAcc2matmirna(object@value)
              NAs <- is.na(Mats[ , 2 ])
              ## show a warning if the ID was not found!
              if(any(NAs))
                  warning(paste0("mirfam accession(s) ",
                                 paste(Mats[ NAs, 1 ], collapse=", "),
                                 " not found in mirbase version ",
                                 mirbase.version(), "."))
              Matmirnas <- Mats[ !NAs, 2 ]
              ## return nothing if no miRNA left...
              if(length(Matmirnas)==0)
                  return(NULL)
              object@value <- Matmirnas
              paste(column(object, db), .where(object))
          })






