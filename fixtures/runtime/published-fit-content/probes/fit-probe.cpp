#include <fstream>
#include <iostream>
#include <iterator>
#include <vector>
#include <cmath>
#include <cstdlib>
#include <array>
#include "rive/file.hpp"
#include "rive/artboard.hpp"
#include "rive/layout_component.hpp"
#include "rive/animation/state_machine_instance.hpp"
#include "rive/viewmodel/viewmodel_instance.hpp"
#include "rive/viewmodel/viewmodel_instance_number.hpp"
#include "utils/no_op_factory.hpp"
int main(int argc,char**argv) {
 if(argc!=2)return 1;
 std::ifstream in(argv[1],std::ios::binary);std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(in)),{});
 rive::NoOpFactory factory;rive::ImportResult result;auto file=rive::File::import(bytes,&factory,&result);if(!file)return 2;
 bool control=std::string(argv[1]).find("no-binding")!=std::string::npos;
 auto schema=file->viewModel("$nuxie.presentation");if(!schema)return 3;
 for(auto name:{"sheet","fill-child","background","sheet"}) {
  auto board=file->artboardNamed(name);auto other=file->artboardNamed(name);if(!board||!other)return 4;
  auto root=file->createDefaultViewModelInstance(board.get());auto otherRoot=file->createDefaultViewModelInstance(other.get());board->bindViewModelInstance(root);other->bindViewModelInstance(otherRoot);
  auto machine=board->stateMachineAt(0);auto otherMachine=other->stateMachineAt(0);if(!machine||!otherMachine)return 5;machine->bindViewModelInstance(root);otherMachine->bindViewModelInstance(otherRoot);
  auto global=file->createDefaultViewModelInstance(schema);auto otherGlobal=file->createDefaultViewModelInstance(schema);
  if(!board->setGlobalViewModelInstance("$nuxie.presentation",global)||!other->setGlobalViewModelInstance("$nuxie.presentation",otherGlobal))return 6;
  board->bind();other->bind();auto value=global->propertyValue("heightMode")->as<rive::ViewModelInstanceNumber>();
  other->width(500);other->height(700);otherMachine->advanceAndApply(0);
  for(auto width:{300.0f,500.0f})for(auto mode:(std::getenv("FIRST_HUG")?std::array<float,3>{2,0,2}:std::array<float,3>{0,2,0})) {
   board->width(width);board->height(700);value->propertyValue(mode);machine->advanceAndApply(0);otherMachine->advanceAndApply(0);
   std::cout<<name<<" mode="<<mode<<" width="<<board->layoutWidth()<<" height="<<board->layoutHeight()<<" other="<<other->layoutHeight()<<"\n";
   if(std::fabs(other->layoutHeight()-700)>0.001)return 7;
   if((mode==0||control)&&std::fabs(board->layoutHeight()-700)>0.001)return 8;
   if(std::string(name)=="sheet"&&mode==2&&!control&&std::fabs(board->layoutHeight()-152)>0.001)return 9;
   if(std::fabs(board->layoutWidth()-width)>0.001)return 10;
  }
 }
}
