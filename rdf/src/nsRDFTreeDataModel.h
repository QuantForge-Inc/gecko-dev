/* -*- Mode: C++; tab-width: 8; indent-tabs-mode: nil; c-basic-offset: 4 -*-
 *
 * The contents of this file are subject to the Netscape Public License
 * Version 1.0 (the "NPL"); you may not use this file except in
 * compliance with the NPL.  You may obtain a copy of the NPL at
 * http://www.mozilla.org/NPL/
 *
 * Software distributed under the NPL is distributed on an "AS IS" basis,
 * WITHOUT WARRANTY OF ANY KIND, either express or implied. See the NPL
 * for the specific language governing rights and limitations under the
 * NPL.
 *
 * The Initial Developer of this code under the NPL is Netscape
 * Communications Corporation.  Portions created by Netscape are
 * Copyright (C) 1998 Netscape Communications Corporation.  All Rights
 * Reserved.
 */

#ifndef nsRDFTreeDataModel_h__
#define nsRDFTreeDataModel_h__

#include "nsRDFDataModel.h"
#include "nsITreeDataModel.h"
#include "nsVector.h"
#include "rdf.h"

////////////////////////////////////////////////////////////////////////

/**
 * An implementation for the tree widget model.
 */
class nsRDFTreeDataModel : public nsRDFDataModel, nsITreeDataModel {
public:
    nsRDFTreeDataModel(nsIRDFDataBase& db, RDF_Resource& root);
    virtual ~nsRDFTreeDataModel(void);

    ////////////////////////////////////////////////////////////////////////
    // nsISupports interface

    // XXX Note that we'll just use the parent class's implementation
    // of AddRef() and Release()

    // NS_IMETHOD_(nsrefcnt) AddRef(void);
    // NS_IMETHOD_(nsrefcnt) Release(void);
    NS_IMETHOD QueryInterface(const nsIID& iid, void** result);


    ////////////////////////////////////////////////////////////////////////
    // nsITreeDataModel interface

    // Column APIs
    NS_IMETHOD GetVisibleColumnCount(int& count) const;
    NS_IMETHOD GetNthColumn(nsITreeColumn*& pColumn, int n) const;
	
    // TreeItem APIs
    NS_IMETHOD GetFirstVisibleItemIndex(int& index) const;
    NS_IMETHOD GetNthTreeItem(nsITreeDMItem*& pItem, int n) const;
    NS_IMETHOD GetItemTextForColumn(nsString& nodeText, nsITreeDMItem* pItem, nsITreeColumn* pColumn) const;


private:
    RDF_Resource& mRoot;
    nsVector      mColumns;
};



#endif // nsRDFTreeDataModel_h__
